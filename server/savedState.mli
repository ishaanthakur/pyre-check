(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Pyre

exception IncompatibleState of string

(* Exposed for testing. *)
val restore_symbolic_links
  :  changed_paths:Path.t list ->
  local_root:Path.t ->
  get_old_link_path:(Path.t -> Path.t option) ->
  Path.t list

val compute_locally_changed_files
  :  scheduler:Scheduler.t ->
  configuration:Configuration.Analysis.t ->
  File.t list

val load : server_configuration:Configuration.Server.t -> connections:State.connections -> State.t

val save
  :  configuration:Configuration.Analysis.t ->
  errors:Analysis.Error.t list File.Handle.Table.t ->
  saved_state_path:string ->
  unit
