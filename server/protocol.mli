(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Analysis
open Pyre

module DefinitionRequest : sig
  type t = {
    id: LanguageServer.Types.RequestId.t;
    file: File.t;
    position: Location.position
  }
  [@@deriving eq, show]
end

type client =
  | FileNotifier
  | Persistent
[@@deriving eq, show]

module TypeQuery : sig
  type serialized_ocaml_value =
    | SerializedValue of { serialized_key: string; serialized_value: string }
    | SerializedPair of
        { serialized_key: string;
          first_serialized_value: string;
          second_serialized_value: string
        }
  [@@deriving eq, show, to_yojson]

  type request =
    | Attributes of Reference.t
    | Callees of Reference.t
    | ComputeHashesToKeys
    | CoverageInFile of File.t
    | DecodeOcamlValues of serialized_ocaml_value list
    | DependentDefines of File.t list
    | DumpDependencies of File.t
    | DumpMemoryToSqlite of Path.t
    | IsCompatibleWith of Expression.t * Expression.t
    | Join of Expression.t * Expression.t
    | LessOrEqual of Expression.t * Expression.t
    | Meet of Expression.t * Expression.t
    | Methods of Reference.t
    | NormalizeType of Expression.t
    | PathOfModule of Reference.t
    | SaveServerState of Path.t
    | Signature of Reference.t
    | Superclasses of Expression.t
    | Type of Expression.t
    | TypeAtPosition of { file: File.t; position: Location.position }
    | TypesInFile of File.t
    | ValidateTaintModels of Path.t option
  [@@deriving eq, show]

  type coverage_level =
    | Typed
    | Partial
    | Untyped
  [@@deriving eq, show]

  type attribute = {
    name: string;
    annotation: Type.t
  }
  [@@deriving eq, show, to_yojson]

  type method_representation = {
    name: string;
    parameters: Type.t list;
    return_annotation: Type.t
  }
  [@@deriving eq, show, to_yojson]

  type found_parameter = {
    parameter_name: string;
    annotation: Type.t option
  }
  [@@deriving eq, show, to_yojson]

  type found_signature = {
    return_type: Type.t option;
    parameters: found_parameter list
  }
  [@@deriving eq, show, to_yojson]

  type type_at_location = {
    location: Location.Instantiated.t;
    annotation: Type.t
  }
  [@@deriving eq, show, to_yojson]

  type coverage_at_location = {
    location: Location.Instantiated.t;
    coverage: coverage_level
  }
  [@@deriving eq, show, to_yojson]

  type decoded_value =
    | DecodedValue of
        { serialized_key: string;
          kind: string;
          actual_key: string;
          actual_value: string option
        }
    | DecodedPair of
        { serialized_key: string;
          kind: string;
          actual_key: string;
          first_value: string option;
          second_value: string option;
          equal: bool
        }
  [@@deriving eq, show, to_yojson]

  type decoded = {
    decoded: decoded_value list;
    undecodable_keys: string list
  }
  [@@deriving eq, show, to_yojson]

  type compatibility = {
    actual: Type.t;
    expected: Type.t;
    result: bool
  }
  [@@derving eq, show]

  type key_mapping = {
    hash: string;
    key: string
  }
  [@@deriving eq, show, to_yojson]

  type base_response =
    | Boolean of bool
    | Callees of Dependencies.Callgraph.callee list
    | Compatibility of compatibility
    | CoverageAtLocations of coverage_at_location list
    | Decoded of decoded
    | FoundAttributes of attribute list
    | FoundKeyMapping of key_mapping list
    | FoundMethods of method_representation list
    | FoundPath of string
    | FoundSignature of found_signature list
    | Path of Pyre.Path.t
    | References of Reference.t list
    | Success of string
    | Superclasses of Type.t list
    | Type of Type.t
    | TypeAtLocation of type_at_location
    | TypesAtLocations of type_at_location list
  [@@deriving eq, show, to_yojson]

  type response =
    | Response of base_response
    | Error of string
  [@@deriving eq, show, to_yojson]
end

module Request : sig
  type t =
    | ClientConnectionRequest of client
    | ClientExitRequest of client
    | ClientShutdownRequest of LanguageServer.Types.RequestId.t
    | CloseDocument of File.t
    | CodeActionRequest of
        { id: LanguageServer.Types.RequestId.t;
          uri: LanguageServer.Types.DocumentUri.t;
          diagnostics: LanguageServer.Types.Diagnostic.t list;
          file: File.t
        }
    | DisplayTypeErrors of File.t list
    | ExecuteCommandRequest of
        { id: LanguageServer.Types.RequestId.t;
          arguments: LanguageServer.Types.CommandArguments.t list
        }
    | GetDefinitionRequest of DefinitionRequest.t
    | HoverRequest of DefinitionRequest.t
    | LanguageServerProtocolRequest of string
    | OpenDocument of File.t
    | RageRequest of LanguageServer.Types.RequestId.t
    | DocumentChange of File.t
    | SaveDocument of File.t
    | StopRequest
    | TypeCheckRequest of File.t list
    | TypeCoverageRequest of { file: File.t; id: LanguageServer.Types.RequestId.t }
    | TypeQueryRequest of TypeQuery.request
  [@@deriving eq, show]

  type origin =
    | PersistentSocket of Unix.File_descr.t
    | NewConnectionSocket of Unix.File_descr.t
    | FileNotifier
    | Background

  val origin_name : origin -> string

  val name : t -> string
end

type response =
  | LanguageServerProtocolResponse of string
  | ClientConnectionResponse of client
  | ClientExitResponse of client
  | TypeCheckResponse of (File.Handle.t * Error.t list) list
  | TypeQueryResponse of TypeQuery.response
  | StopResponse
  | GetDefinitionResponse of Location.Instantiated.t option
  | HoverResponse of Location.Instantiated.t option
[@@deriving eq, show]
