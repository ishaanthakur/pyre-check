(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Pyre
open PyreParser

type 'success parse_result =
  | Success of 'success
  | SyntaxError of File.Handle.t
  | SystemError of File.Handle.t

let parse_source ~configuration ?(show_parser_errors = true) file =
  let parse_lines ~handle lines =
    let metadata = Source.Metadata.parse (File.Handle.show handle) lines in
    try
      let statements = Parser.parse ~handle lines in
      let hash = [%hash: string list] lines in
      Success
        (Source.create
           ~docstring:(Statement.extract_docstring statements)
           ~hash
           ~metadata
           ~handle
           ~qualifier:(Source.qualifier ~handle)
           statements)
    with
    | Parser.Error error ->
        if show_parser_errors then
          Log.log ~section:`Parser "%s" error;
        SyntaxError handle
    | Failure error ->
        Log.error "%s" error;
        SystemError handle
  in
  File.handle ~configuration file
  |> fun handle ->
  Path.readlink (File.path file)
  >>| (fun target -> Ast.SharedMemory.SymlinksToPaths.add target (File.path file))
  |> ignore;
  File.lines file >>| parse_lines ~handle |> Option.value ~default:(SystemError handle)


module FixpointResult = struct
  type t = {
    parsed: File.Handle.t parse_result list;
    not_parsed: File.t list
  }

  let merge
      { parsed = left_parsed; not_parsed = left_not_parsed }
      { parsed = right_parsed; not_parsed = right_not_parsed }
    =
    { parsed = left_parsed @ right_parsed; not_parsed = left_not_parsed @ right_not_parsed }
end

let parse_sources_job ~preprocessing_state ~show_parser_errors ~force ~configuration ~files =
  let parse ({ FixpointResult.parsed; not_parsed } as result) file =
    let use_parsed_source source =
      let source =
        match preprocessing_state with
        | Some state -> ProjectSpecificPreprocessing.preprocess ~state source
        | None -> source
      in
      let store_result ~preprocessed ~file =
        let add_module_from_source
            { Source.qualifier;
              handle;
              statements;
              metadata = { Source.Metadata.local_mode; _ };
              _
            }
          =
          Module.create
            ~qualifier
            ~local_mode
            ~handle
            ~stub:(File.Handle.is_stub handle)
            statements
          |> fun ast_module -> Ast.SharedMemory.Modules.add ~qualifier ~ast_module
        in
        add_module_from_source preprocessed;
        let handle = File.handle ~configuration file in
        Ast.SharedMemory.Handles.add_handle_hash ~handle:(File.Handle.show handle);
        Plugin.apply_to_ast preprocessed |> Ast.SharedMemory.Sources.add handle;
        handle
      in
      if force then
        let handle =
          Analysis.Preprocessing.preprocess source
          |> fun preprocessed -> store_result ~preprocessed ~file
        in
        { result with parsed = Success handle :: parsed }
      else
        match Analysis.Preprocessing.try_preprocess source with
        | Some preprocessed ->
            let handle = store_result ~preprocessed ~file in
            { result with parsed = Success handle :: parsed }
        | None -> { result with not_parsed = file :: not_parsed }
    in
    parse_source ~configuration ~show_parser_errors file
    |> fun parsed_source ->
    match parsed_source with
    | Success parsed -> use_parsed_source parsed
    | SyntaxError error -> { result with parsed = SyntaxError error :: parsed }
    | SystemError error -> { result with parsed = SystemError error :: parsed }
  in
  List.fold ~init:{ FixpointResult.parsed = []; not_parsed = [] } ~f:parse files


type parse_sources_result = {
  parsed: File.Handle.t list;
  syntax_error: File.Handle.t list;
  system_error: File.Handle.t list
}

let parse_sources ~configuration ~scheduler ~preprocessing_state ~files =
  let rec fixpoint ?(force = false) ({ FixpointResult.parsed; not_parsed } as input_state) =
    let { FixpointResult.parsed = new_parsed; not_parsed = new_not_parsed } =
      Scheduler.map_reduce
        scheduler
        ~configuration
        ~initial:{ FixpointResult.parsed = []; not_parsed = [] }
        ~map:(fun _ files ->
          parse_sources_job
            ~show_parser_errors:(List.length parsed = 0)
            ~preprocessing_state
            ~force
            ~configuration
            ~files)
        ~reduce:FixpointResult.merge
        ~inputs:not_parsed
        ()
    in
    if List.is_empty new_not_parsed then (* All done. *)
      parsed @ new_parsed
    else if List.is_empty new_parsed then
      (* No progress was made, force the parse ignoring all temporary errors. *)
      fixpoint ~force:true input_state
    else (* We made some progress, continue with the fixpoint. *)
      fixpoint { parsed = parsed @ new_parsed; not_parsed = new_not_parsed }
  in
  let result = fixpoint { parsed = []; not_parsed = files } in
  let () =
    let get_qualifier file =
      File.handle ~configuration file |> fun handle -> Source.qualifier ~handle
    in
    List.map files ~f:get_qualifier
    |> fun qualifiers -> Ast.SharedMemory.Modules.remove ~qualifiers
  in
  let categorize ({ parsed; syntax_error; system_error } as result) parse_result =
    match parse_result with
    | Success handle -> { result with parsed = handle :: parsed }
    | SyntaxError handle -> { result with syntax_error = handle :: syntax_error }
    | SystemError handle -> { result with system_error = handle :: system_error }
  in
  List.fold result ~init:{ parsed = []; syntax_error = []; system_error = [] } ~f:categorize


let log_parse_errors ~syntax_error ~system_error =
  let syntax_errors = List.length syntax_error in
  let system_errors = List.length system_error in
  let count = syntax_errors + system_errors in
  if count > 0 then (
    let hint =
      if syntax_errors > 0 && not (Log.is_enabled `Parser) then
        Format.asprintf
          " Run `pyre %s` without `--hide-parse-errors` for more details%s."
          ( try Array.nget Sys.argv 1 with
          | _ -> "restart" )
          (if system_errors > 0 then " on the syntax errors" else "")
      else
        ""
    in
    let details =
      let to_string count description =
        Format.sprintf "%d %s%s" count description (if count == 1 then "" else "s")
      in
      if syntax_errors > 0 && system_errors > 0 then
        Format.sprintf
          ": %s, %s"
          (to_string syntax_errors "syntax error")
          (to_string system_errors "system error")
      else if syntax_errors > 0 then
        " due to syntax errors"
      else
        " due to system errors"
    in
    Log.warning "Could not parse %d file%s%s!%s" count (if count > 1 then "s" else "") details hint;
    let trace list = List.map list ~f:File.Handle.show |> String.concat ~sep:";" in
    Statistics.event
      ~flush:true
      ~name:"parse errors"
      ~integers:["syntax errors", syntax_errors; "system errors", system_errors]
      ~normals:
        ["syntax errors trace", trace syntax_error; "system errors trace", trace system_error]
      () )


let find_stubs ({ Configuration.Analysis.local_root; search_path; excludes; _ } as configuration) =
  let stubs =
    let stubs root =
      let search_root = SearchPath.to_path root in
      Log.info "Finding type stubs in `%a`..." Path.pp search_root;
      let directory_filter path =
        let is_python_2_directory path =
          String.is_suffix ~suffix:"/2" path || String.is_suffix ~suffix:"/2.7" path
        in
        (not (is_python_2_directory path))
        && not (List.exists excludes ~f:(fun regexp -> Str.string_match regexp path 0))
      in
      let file_filter path =
        String.is_suffix path ~suffix:".pyi"
        && not (List.exists excludes ~f:(fun regexp -> Str.string_match regexp path 0))
      in
      (* The search path might live under the local root. If that's the case, we should make sure
         that we don't add these stubs when analyzing the local root, as that would clobber the
         order. The method of solving this is by only adding handles that correspond directly to
         the root. *)
      let keep path =
        let reconstructed =
          File.create path
          |> File.handle ~configuration
          |> File.Handle.show
          |> fun relative -> Path.create_relative ~root:(SearchPath.get_root root) ~relative
        in
        Path.equal reconstructed path
      in
      Path.list ~file_filter ~directory_filter ~root:search_root () |> List.filter ~f:keep
    in
    List.map ~f:stubs (SearchPath.Root local_root :: search_path)
  in
  let modules =
    let modules root =
      Log.info "Finding external sources in `%a`..." Path.pp root;
      let directory_filter path =
        not (List.exists excludes ~f:(fun regexp -> Str.string_match regexp path 0))
      in
      let file_filter path =
        String.is_suffix ~suffix:".py" path
        && not (List.exists excludes ~f:(fun regexp -> Str.string_match regexp path 0))
      in
      Path.list ~file_filter ~directory_filter ~root ()
    in
    search_path |> List.map ~f:SearchPath.to_path |> List.map ~f:modules
  in
  List.append stubs modules |> List.concat


let find_sources { Configuration.Analysis.local_root; excludes; extensions; _ } =
  let directory_filter path =
    (not (String.is_substring ~substring:".pyre/resource_cache" path))
    && not (List.exists excludes ~f:(fun regexp -> Str.string_match regexp path 0))
  in
  let valid_suffixes = ".py" :: extensions in
  let file_filter path =
    let extension =
      Filename.split_extension path
      |> snd
      >>| (fun extension -> "." ^ extension)
      |> Option.value ~default:""
    in
    List.exists ~f:(String.equal extension) valid_suffixes
    && not (List.exists excludes ~f:(fun regexp -> Str.string_match regexp path 0))
  in
  Path.list ~file_filter ~directory_filter ~root:local_root ()


let find_stubs_and_sources configuration =
  (* If two directories contain the same source file:
   *  - Prefer external sources over internal sources
   *  - Prefer the one that appears earlier in the search path. *)
  let filter_interfering_sources ~configuration (stubs : Path.t list) (sources : Path.t list) =
    let qualifiers = Reference.Hash_set.create () in
    let keep path =
      let handle = File.create path |> File.handle ~configuration in
      let qualifier = Ast.Source.qualifier ~handle in
      match Hash_set.strict_add qualifiers qualifier with
      | Result.Ok () -> true
      | Result.Error _ -> false
    in
    let stubs = List.filter ~f:keep stubs in
    let sources = List.filter ~f:keep sources in
    stubs @ sources
  in
  let stubs = find_stubs configuration in
  let sources = find_sources configuration in
  filter_interfering_sources ~configuration stubs sources


let parse_all scheduler ~configuration =
  let paths = find_stubs_and_sources configuration in
  let timer = Timer.start () in
  Log.info "Parsing %d stubs and sources..." (List.length paths);
  let { parsed; syntax_error; system_error } =
    let preprocessing_state =
      let to_handle path =
        try File.create path |> File.handle ~configuration |> Option.some with
        | File.NonexistentHandle _ -> None
      in
      ProjectSpecificPreprocessing.initial (List.filter_map paths ~f:to_handle)
    in
    parse_sources
      ~configuration
      ~scheduler
      ~preprocessing_state:(Some preprocessing_state)
      ~files:(List.map ~f:File.create paths)
  in
  log_parse_errors ~syntax_error ~system_error;
  Statistics.performance ~name:"sources parsed" ~timer ();
  parsed
