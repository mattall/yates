open Core.Std
open Frenetic_Network
open Net
open Kulfi_Traffic
open Kulfi_Types
open Kulfi_Util
open Simulation_Util

(********************************************************************)
(**************** Generate various failure scenarios ****************)
(********************************************************************)

let reverse_edge topo e = match Topology.inverse_edge topo e with
          | Some x -> x
          | None -> assert false

(* helper: failure prob of a link is proportional to its congestion ^ alpha *)
let rec get_util_based_failure_scenario (topo:topology) (alpha:float) (utils:congestion EdgeMap.t) : failure =
  (* don't fail links connecting hosts *)
  let failure_weights = utils
    |> EdgeMap.to_alist
    |> List.filter ~f:(fun (e,_) -> edge_connects_switches e topo)
    |> List.map ~f:(fun (e,c) -> (e, c ** alpha)) in
  let total_weight = List.fold_left failure_weights
    ~init:0.
    ~f:(fun acc (_,w) -> acc +. w) in
  if total_weight = 0. then EdgeSet.empty
  else
    let rand = Random.float total_weight in
    let first_el = List.hd_exn failure_weights in
    let (e,_),_ = List.fold_left failure_weights
      ~init:(first_el, rand)
      ~f:(fun (selected,sum) (e,w) ->
        if sum <= 0. then (selected,sum)
        else ((e,w), sum -. w)) in
    let e' = match Topology.inverse_edge topo e with
            | Some x -> x
            | None -> assert false in
    let fail = EdgeSet.add (EdgeSet.singleton e) e' in
    if check_connectivity_after_failure topo fail then fail
    else get_util_based_failure_scenario topo alpha utils

(* Given link congestions, select top n links that do not partition the network *)
let rec get_max_util_failure (topo:topology) (num_fail:int) (utils: congestion EdgeMap.t): failure =
  (* don't fail links connecting hosts *)
  let sorted_edge_utils = utils
      |> EdgeMap.to_alist
      |> List.filter ~f:(fun (e,_) -> edge_connects_switches e topo)
      |> List.sort ~cmp:(fun x y -> Float.compare (snd y) (snd x)) in

  (*let _ = List.iter sorted_edge_utils ~f:(fun (e,c) -> Printf.printf "%s : %f\n%!" (string_of_edge topo e) c;) in*)
  let max_util_links_set,_ = List.fold_left sorted_edge_utils
    ~init:(EdgeSet.empty, num_fail)
    ~f:(fun acc (e,_) ->
      let (fail_set, nf) = acc in
      if nf = 0 then acc
      else if EdgeSet.mem fail_set e then acc
      else
        let fail_set_cand = EdgeSet.add (EdgeSet.add fail_set e) (reverse_edge topo e) in
        if check_connectivity_after_failure topo fail_set_cand then (fail_set_cand, nf-1)
        else acc) in
  (*let _ = EdgeSet.iter max_util_links_set ~f:(fun e -> Printf.printf "%s \t%!" (string_of_edge topo e);) in*)
  max_util_links_set

let get_spf_util_based_failure (topo:topology) (actual:demands) (alpha:float) : failure =
  Kulfi_Routing.Spf.solve topo SrcDstMap.empty
    |> congestion_of_paths topo actual
    |> get_util_based_failure_scenario topo alpha


(* Return top utilized SPF links, whose failure doesn't partition the network *)
let rec get_spf_max_util_link (topo:topology) (actual:demands) (num_fail:int) : failure =
  if num_fail = 0 then EdgeSet.empty
  else
    let max_util_link =
      Kulfi_Routing.Spf.solve topo SrcDstMap.empty
      |> congestion_of_paths topo actual
      |> get_max_util_failure topo 1 in
    let topo' = update_topo_with_failure topo max_util_link in
    let rest_fail = get_spf_max_util_link topo' actual (num_fail-1) in
    EdgeSet.union max_util_link rest_fail



(* get a random failure of n edges, keeping the network connected *)
let rec get_random_failure (topo:topology) (num_fail:int) : failure =
  let rec add_new_elem (selected : EdgeSet.t) (all_edges : edge List.t) =
    let rand = Random.int (List.length all_edges) in
    let rand_edge = List.nth_exn all_edges rand in
    if EdgeSet.mem selected rand_edge then add_new_elem selected all_edges
    else
      let rev_edge = match Topology.inverse_edge topo rand_edge with
        | Some x -> x
        | None -> assert false in
      let selected = EdgeSet.add selected rand_edge in
      EdgeSet.add selected rev_edge in

  let all_edges = EdgeSet.elements (Topology.edges topo) in
  let fail_set = List.fold_left (range 0 num_fail)
    ~init:EdgeSet.empty
    ~f:(fun acc i ->
      add_new_elem acc all_edges) in
  if check_connectivity_after_failure topo fail_set then fail_set
  else get_random_failure topo num_fail


(* Create a test failure scenario failing edges uniformly based on SPF congestion *)
let rec get_test_failure_scenario (topo:topology) (actual:demands) (iter_pos:float) (num_fail:int): failure =
  if (Float.of_int (Topology.num_edges topo))/.2. -.
  (Float.of_int(Topology.num_vertexes topo)) < (Float.of_int (num_fail)) then failwith "Not good enough topo for num_fail failures"
  else
  if num_fail = 0 then EdgeSet.empty else
  if num_fail > 1 then get_random_failure topo num_fail else

  let iter_pos = min 1. iter_pos in
  let sorted_edge_utils =
    Kulfi_Routing.Spf.solve topo SrcDstMap.empty
    |> congestion_of_paths topo actual
    |> EdgeMap.to_alist
    |> List.filter ~f:(fun (e,_) -> edge_connects_switches e topo)
    |> List.sort ~cmp:(fun x y -> Float.compare (snd y) (snd x)) in
  (*let _ = List.iter sorted_edge_utils ~f:(fun (e,c) -> Printf.printf "%s : %f\n%!" (string_of_edge topo e) c;) in*)
  let f_sel_pos = ((Float.of_int (List.length sorted_edge_utils - 1))) *. iter_pos in
  let sel_pos = Int.of_float (Float.round_down f_sel_pos) in
  let (e,_) = List.nth_exn sorted_edge_utils sel_pos in
  let e' = match Topology.inverse_edge topo e with
          | Some x -> x
          | None -> assert false in
  let f = EdgeSet.add (EdgeSet.singleton e) e' in
  if check_connectivity_after_failure topo f then f
  else
    if iter_pos >= 1. then EdgeSet.empty
    else
      get_test_failure_scenario topo actual (iter_pos +. (1. /. Float.of_int (List.length sorted_edge_utils))) num_fail

(* Pre-compute failure scenario for each TM - to be consistent across TE algorithms *)
let get_failure_scenarios (topo:topology) (demand_file:string) (host_file:string) (iters:int) (num_failures:int) (scale:float) : (EdgeSet.t List.t) =
  let (demand_host_map, demand_ic) = open_demands demand_file host_file topo in
  let fail_start_iter = 0 in
  let iterations = range fail_start_iter iters in
  let failure_scenarios = List.rev(List.fold_left iterations
    ~init:[]
    ~f:(fun acc n ->
      let actual = next_demand ~scale:scale demand_ic demand_host_map in
      let failing_edges =
      get_spf_max_util_link topo actual num_failures in
      (* get_util_based_failure_scenario topo num_failures iexp_congestions n*)
      (*get_spf_util_based_failure topo actual exp_congestions num_failures in*)
      (*get_test_failure_scenario topo actual ((Float.of_int (n - fail_start_iter)) /. (Float.of_int iters)) num_failures in*)
      (*Printf.printf "Selected failure: %s\n%!" (dump_edges topo (EdgeSet.elements failing_edges));*)
      failing_edges::acc)) in
  close_demands demand_ic;
  failure_scenarios

(* Compute all possible failure scenarios with num_failures link failing, while not partitioning the network *)
let get_all_possible_failures (topo:topology) (num_failures:int) : (failure List.t) =
  (* List of single link failures *)
  let all_single_failures =
    EdgeSet.fold (Topology.edges topo) ~init:[]
      ~f:(fun acc e ->
        if not (edge_connects_switches e topo) then acc
        else
          let rev_e = reverse_edge topo e in
          let fl = EdgeSet.add (EdgeSet.singleton e) rev_e in
          if List.mem ~equal:EdgeSet.equal acc fl then acc
          else fl::acc)
    |> List.filter ~f:(fun fl -> check_connectivity_after_failure topo fl) in

  let failures = List.fold_left (range 1 num_failures) ~init:all_single_failures
    ~f:(fun partial_acc i ->
      List.fold_left partial_acc ~init:[]
        ~f:(fun acc partial_fl ->
          List.fold_left all_single_failures ~init:acc
            ~f:(fun acc single_fl ->
              if EdgeSet.subset single_fl partial_fl then acc
              else
                let new_failure = EdgeSet.union partial_fl single_fl in
                if check_connectivity_after_failure topo new_failure then new_failure::acc
                else acc))) in
  (*List.iter failures ~f:(fun failing_edges ->
    Printf.printf "Selected failure: %s\n%!" (dump_edges topo (EdgeSet.elements failing_edges)));
  Printf.printf "Total scenarios : %d\n" (List.length failures);*)
  failures