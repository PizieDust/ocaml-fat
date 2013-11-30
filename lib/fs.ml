(*
 * Copyright (C) 2011-2013 Citrix Systems Inc
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open S

module Make = functor(B: BLOCK_DEVICE) -> struct
  type fs = {
    device: B.device;
    boot: Boot_sector.t;
    format: Fat_format.t;
    fat: Entry.fat;
    root: Cstruct.t;
  }

  type block_device = B.device

  exception Block_device_error of B.error

  let (>>|=) m f = m >>= function
  | `Error e -> fail (Block_device_error e)
  | `Ok x -> f x

  let read_sectors device xs =
    let buf = Cstruct.create (List.length xs * 512) in
    let rec split buf =
      if Cstruct.len buf = 0 then []
      else if Cstruct.len buf <= 512 then [ buf ]
      else Cstruct.sub buf 0 512 :: (split (Cstruct.shift buf 512)) in

    let rec loop = function
      | [] -> return ()
      | (sector, buffer) :: xs ->
        B.read device (Int64.of_int sector) [ buffer ] >>|= fun () ->
        loop xs in
    loop (List.combine xs (split buf)) >>= fun () ->
    return buf

  let write_update x ({ Update.offset = offset; data = data } as update) =
    let bps = x.boot.Boot_sector.bytes_per_sector in
    let sector_number = Int64.(div offset (of_int bps)) in
    let sector_offset = Int64.(sub offset (mul sector_number (of_int bps))) in
    let sector = Cstruct.create 512 in
    B.read x.device sector_number [ sector ] >>|= fun () ->
    Update.apply sector { update with Update.offset = sector_offset };
    B.write x.device sector_number [ sector ] >>|= fun () ->
    return ()

  let make device size =
    let boot = Boot_sector.make size in
    ( match Boot_sector.detect_format boot with
      | `Ok x -> return x
      | `Error x -> fail x ) >>= fun format ->

    let sector = Cstruct.create 512 in
    Boot_sector.marshal sector boot;

    let fat = Entry.make boot format in
    let fat_sectors = Boot_sector.sectors_of_fat boot in
    let fat_writes = Update.(map (split (from_cstruct 0L fat) 512) fat_sectors 512) in

    let root_sectors = Boot_sector.sectors_of_root_dir boot in
    let root = Cstruct.create (List.length root_sectors * 512) in
    for i = 0 to Cstruct.len root - 1 do
      Cstruct.set_uint8 root i 0
    done;
    let root_writes = Update.(map (split (from_cstruct 0L root) 512) root_sectors 512) in 

    let x = { device; boot = boot; format = format; fat = fat; root = root } in
    write_update x (Update.from_cstruct 0L sector) >>= fun () ->
    Lwt_list.iter_s (write_update x) fat_writes >>= fun () ->
    Lwt_list.iter_s (write_update x) root_writes >>= fun () ->
    return x

  let openfile device =
    let sector = Cstruct.create 512 in
    B.read device 0L [ sector ] >>|= fun () ->
    ( match Boot_sector.unmarshal sector with
      | `Ok x -> return x
      | `Error x -> fail (Failure x) ) >>= fun boot ->
    ( match Boot_sector.detect_format boot with
      | `Ok x -> return x
      | `Error x -> fail x ) >>= fun format ->
    read_sectors device (Boot_sector.sectors_of_fat boot) >>= fun fat ->
    read_sectors device (Boot_sector.sectors_of_root_dir boot) >>= fun root ->
    return { device; boot; format; fat; root }

  type file = Path.t
  let file_of_path fs x = x

  type find =
    | Dir of Name.r list
    | File of Name.r

  let sectors_of_chain x chain =
    List.concat (List.map (Boot_sector.sectors_of_cluster x.boot) chain)
       
  let sectors_of_file x { Name.start_cluster = cluster; file_size = file_size; subdir = subdir } =
    let chain = Entry.follow_chain x.format x.fat cluster in
    sectors_of_chain x chain

  let read_whole_file x { Name.dos = _, ({ Name.file_size = file_size; subdir = subdir } as f) } =
    read_sectors x.device (sectors_of_file x f)

  (** [find x path] returns a [find_result] corresponding to the object
      stored at [path] *)
  let find x path : [ `Ok of find | `Error of Error.t ] Lwt.t =
    let readdir = function
      | Dir ds -> return ds
      | File d ->
        read_whole_file x d >>= fun buf ->
        return (Name.list buf) in
    let rec inner sofar current = function
    | [] ->
      begin match current with
      | Dir ds -> return (`Ok (Dir ds))
      | File { Name.dos = _, { Name.subdir = true } } ->
        readdir current >>= fun names ->
        return (`Ok (Dir names))
      | File ( { Name.dos = _, { Name.subdir = false } } as d ) ->
        return (`Ok (File d))
      end
    | p :: ps ->
      readdir current >>= fun entries ->
      begin match Name.find p entries, ps with
      | Some { Name.dos = _, { Name.subdir = false } }, _ :: _ ->
        return (`Error (Error.Not_a_directory (Path.of_string_list (List.rev (p :: sofar)))))
      | Some d, _ ->
        inner (p::sofar) (File d) ps
      | None, _ ->
        return (`Error(Error.No_directory_entry (Path.of_string_list (List.rev sofar), p)))
      end in
    inner [] (Dir (Name.list x.root)) (Path.to_string_list path)

  module Location = struct
    (* Files and directories are stored in a location *)
    type t =
    | Chain of int list (* a chain of clusters *)
    | Rootdir           (* the root directory area *)

    let to_string = function
    | Chain xs -> Printf.sprintf "Chain [ %s ]" (String.concat "; " (List.map string_of_int xs))
    | Rootdir -> "Rootdir"

    (** [chain_of_file x path] returns [Some chain] where [chain] is the chain
        corresponding to [path] or [None] if [path] cannot be found or if it
        is / and hasn't got a chain. *)
    let chain_of_file x path =
      if Path.is_root path then return None
      else
        let parent_path = Path.directory path in
        find x parent_path >>= fun entry ->
        match entry with
        | `Ok (Dir ds) ->
          begin match Name.find (Path.filename path) ds with
          | None -> assert false
          | Some f ->
            let start_cluster = (snd f.Name.dos).Name.start_cluster in
            return (Some(Entry.follow_chain x.format x.fat start_cluster))
          end
        | _ -> return None

    (* return the storage location of the object identified by [path] *)
    let of_file x path =
      chain_of_file x path >>= function
      | None -> return Rootdir
      | Some c -> return (Chain c)

    let to_sectors x = function
      | Chain clusters -> sectors_of_chain x clusters
      | Rootdir -> Boot_sector.sectors_of_root_dir x.boot

  end

  exception Fs_error of Error.t

  let (>>|=) m f = m >>= function
  | `Error e -> fail (Fs_error e)
  | `Ok x -> f x

  (** [write_to_location x path location update] applies [update]
      to the data stored in the object at [path] which is currently
      stored at [location]. If [location] is a chain of clusters then
      it will be extended. *)
  let rec write_to_location x path location update : unit Lwt.t =
    let bps = x.boot.Boot_sector.bytes_per_sector in
    let spc = x.boot.Boot_sector.sectors_per_cluster in
    let updates = Update.split update bps in

    let sectors = Location.to_sectors x location in
    (* This would be a good point to see whether we need to allocate
       new sectors and do that too. *)
    let current_bytes = bps * (List.length sectors) in
    let bytes_needed = max 0L (Int64.(sub (Update.total_length update) (of_int current_bytes))) in
    let clusters_needed =
      let bpc = Int64.of_int(spc * bps) in
      Int64.(to_int(div (add bytes_needed (sub bpc 1L)) bpc)) in
    ( match location, bytes_needed > 0L with
      | Location.Rootdir, true ->
	fail (Fs_error Error.No_space)
      | (Location.Rootdir | Location.Chain _), false ->
	let writes = Update.map updates sectors bps in
        Lwt_list.iter_s (write_update x) writes >>= fun () ->
	if location = Location.Rootdir then Update.apply x.root update;
	return location
      | Location.Chain cs, true ->
	let last = if cs = [] then None else Some (List.hd (List.rev cs)) in
	let new_clusters = Entry.extend x.boot x.format x.fat last clusters_needed in
	let fat_sectors = Boot_sector.sectors_of_fat x.boot in
	let new_sectors = sectors_of_chain x new_clusters in
	let data_writes = Update.map updates (sectors @ new_sectors) bps in
        Lwt_list.iter_s (write_update x) data_writes >>= fun () ->
        let fat_writes = Update.(map (split (from_cstruct 0L x.fat) bps) fat_sectors bps) in
        Lwt_list.iter_s (write_update x) fat_writes >>= fun () ->
        return (Location.Chain (cs @ new_clusters)))  >>= fun location ->
    match location with
    | Location.Chain [] ->
      (* In the case of a previously empty file (location = Chain []), we
         have extended the chain (location = Chain (_ :: _)) so it's safe to
         call List.hd *)
      assert false
    | Location.Chain (start_cluster :: _) ->
	update_directory_containing x path
	  (fun bits ds ->
	    let filename = Path.filename path in
	    match Name.find filename ds with
	      | None ->
		fail (Fs_error (Error.No_directory_entry (Path.directory path, Path.filename path)))
	      | Some d ->
		let file_size = Name.file_size_of d in
		let new_file_size = max file_size (Int32.of_int (Int64.to_int (Update.total_length update))) in
                let updates = Name.modify bits filename new_file_size start_cluster in
                return updates
	  )
    | Location.Rootdir -> return () (* the root directory itself has no attributes *)

  and update_directory_containing x path f =
    let parent_path = Path.directory path in
    find x parent_path >>= function
      | `Error x -> fail (Fs_error x)
      | `Ok (File _) -> fail (Fs_error (Error.Not_a_directory parent_path))
      | `Ok (Dir ds) ->
        Location.of_file x parent_path >>= fun location ->
        let sectors = Location.to_sectors x location in
        read_sectors x.device sectors >>= fun contents ->
	f contents ds >>= fun updates ->
        Lwt_list.iter_s (write_to_location x parent_path location) updates

  let create_common x path dir_entry =
    let filename = Path.filename path in
    update_directory_containing x path
      (fun contents ds ->
	if Name.find filename ds <> None
	then fail (Fs_error (Error.File_already_exists filename))
	else return (Name.add contents dir_entry)
      )

  let wrap f =
    catch
      (fun () -> f () >>= fun x -> return (`Ok x))
      (function
       | Fs_error err -> return (`Error err)
       | e -> return (`Error (Error.Unknown_error (Printexc.to_string e)))) 

  (** [write x f offset buf] writes [buf] at [offset] in file [f] on
      filesystem [x] *)
  let write x f offset buf : [ `Ok of unit | `Error of Error.t ] Lwt.t =
    wrap (fun () ->
      (* u is the update, in file co-ordinates *)
      let u = Update.from_cstruct (Int64.of_int offset) buf in
      (* all data is either in the root directory or in a chain of clusters.
         Note even subdirectories are stored in chains of clusters. *)
      Location.of_file x f >>= fun location -> 
      write_to_location x f location u)

  (** [create x path] create a zero-length file at [path] *)
  let create x path : [ `Ok of unit | `Error of Error.t ] Lwt.t =
    wrap (fun () -> create_common x path (Name.make (Path.filename path)))

  (** [mkdir x path] create an empty directory at [path] *)
  let mkdir x path : [ `Ok of unit | `Error of Error.t ] Lwt.t =
    wrap (fun () -> create_common x path (Name.make ~subdir:true (Path.filename path)))

  (** [destroy x path] deletes the entry at [path] *)
  let destroy x path : [ `Ok of unit | `Error of Error.t ] Lwt.t =
    let filename = Path.filename path in
    let do_destroy () =
      update_directory_containing x path
	(fun contents ds ->
	(* XXX check for nonempty *)
	(* XXX delete chain *)
	  if Name.find filename ds = None
	  then fail (Fs_error (Error.No_directory_entry(Path.directory path, filename)))
	  else return (Name.remove contents filename)
	) >>= fun () -> return (`Ok ()) in
    find x path >>= function
      | `Error x -> return (`Error x)
      | `Ok (File _) -> do_destroy ()
      | `Ok (Dir []) -> do_destroy ()
      | `Ok (Dir (_::_)) -> return (`Error(Error.Directory_not_empty(path)))

  let stat x path =
    let entry_of_file f = f in
    find x path >>= function
      | `Error x -> return (`Error x)
      | `Ok (File f) -> return (`Ok (Stat.File (entry_of_file f)))
      | `Ok (Dir ds) ->
	let ds' = List.map entry_of_file ds in
	if Path.is_root path
	then return (`Ok (Stat.Dir (entry_of_file Name.fake_root_entry, ds')))
	else
	  let filename = Path.filename path in
	  let parent_path = Path.directory path in
	  find x parent_path >>= function
	    | `Error x -> return (`Error x)
	    | `Ok (File _) -> assert false (* impossible by initial match *)
	    | `Ok (Dir ds) ->
	      begin match Name.find filename ds with
		| None -> assert false (* impossible by initial match *)
		| Some f ->
		  return (`Ok (Stat.Dir (entry_of_file f, ds')))
	      end

  let read_file x { Name.dos = _, ({ Name.file_size = file_size } as f) } the_start length =
    let bps = x.boot.Boot_sector.bytes_per_sector in
    let the_file = SectorMap.make (sectors_of_file x f) in
    (* If the file is small, truncate length *)
    let length = min length (Int32.to_int file_size - the_start) in
    let preceeding, requested, succeeding = SectorMap.byte_range bps the_start length in
    let to_read = SectorMap.compose requested the_file in
    read_sectors x.device (SectorMap.to_list to_read) >>= fun buffer ->
    let buffer = Cstruct.sub buffer preceeding (Cstruct.len buffer - preceeding - succeeding) in
    return buffer

  let read x path the_start length =
    find x path >>= function
      | `Ok (Dir _) -> return (`Error (Error.Is_a_directory path))
      | `Ok (File f) ->
        read_file x f the_start length >>= fun buffer ->
        return (`Ok [buffer])
      | `Error x -> return (`Error x)

end