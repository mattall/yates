open Core
open Frenetic_kernel.OpenFlow
open Frenetic_kernel.OpenFlow0x01
open Kulfi_Types

val create : topology -> (switchId, flowMod list) Hashtbl.t * (edge, int) Hashtbl.t
