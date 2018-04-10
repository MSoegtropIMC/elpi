(* elpi: embedded lambda prolog interpreter                                  *)
(* license: GNU Lesser General Public License Version 2.1 or later           *)
(* ------------------------------------------------------------------------- *)

module type Runtime = module type of Elpi_runtime_trace_off.Elpi_runtime

let r = ref (module Elpi_runtime_trace_off.Elpi_runtime : Runtime)

let set_runtime = function
  | true  -> r := (module Elpi_runtime_trace_on.Elpi_runtime  : Runtime)
  | false -> r := (module Elpi_runtime_trace_off.Elpi_runtime : Runtime)

let set_trace argv =
  let args = Elpi_trace.parse_argv argv in
  set_runtime !Elpi_trace.debug;
  args

module Setup = struct

type builtins = Elpi_data.Builtin.declaration list

let init ?silent ?lp_syntax ~builtins ~basedir:cwd argv =
  let new_argv = set_trace argv in
  let new_argv, paths =
    let rec aux args paths = function
      | [] -> List.rev args, List.rev paths
      | "-I" :: p :: rest -> aux args (p :: paths) rest
      | x :: rest -> aux (x :: args) paths rest
    in
      aux [] [] new_argv
  in
  Elpi_parser.init ?silent ?lp_syntax ~paths ~cwd ();
  List.iter (function
    | Elpi_data.Builtin.MLCode (p,_) -> Elpi_data.Builtin.register p
    | Elpi_data.Builtin.LPCode _ -> ()
    | Elpi_data.Builtin.LPDoc _ -> ()) builtins;
  new_argv

let trace args =
  match set_trace args with
  | [] -> ()
  | l -> Elpi_util.error ("Elpi_API.trace got unknown arguments: " ^ (String.concat " " l))

let usage =
  "\nParsing options:\n" ^
  "\t-I PATH  search for accumulated files in PATH\n" ^
  Elpi_trace.usage 

let set_warn = Elpi_util.set_warn
let set_error = Elpi_util.set_error
let set_anomaly = Elpi_util.set_anomaly
let set_type_error = Elpi_util.set_type_error
let set_std_formatter = Elpi_util.set_std_formatter
let set_err_formatter = Elpi_util.set_err_formatter

end

module Ast = struct
  type program = Elpi_ast.program
  type query = Elpi_ast.goal
end

module Parse = struct
  let program = Elpi_parser.parse_program
  let goal = Elpi_parser.parse_goal
  let goal_from_stream = Elpi_parser.parse_goal_from_stream
end

module Data = struct
  type term = Elpi_data.term
  type executable = Elpi_data.executable
  type syntactic_constraints = Elpi_data.syntactic_constraints
  type custom_constraints = Elpi_data.custom_constraints
  module StrMap = Elpi_util.StrMap
  type solution = Elpi_data.solution = {
    assignments : term StrMap.t;
    constraints : syntactic_constraints;
    custom_constraints : custom_constraints;
  }
end

module Compile = struct

  type program = Elpi_compiler.program
  type query = Elpi_compiler.query

  let program l = Elpi_compiler.program_of_ast (List.flatten l)
  let query = Elpi_compiler.query_of_ast

  let static_check ?checker ?flags p =
    let module R = (val !r) in let open R in
    let checker = Elpi_util.option_map List.flatten checker in
    Elpi_compiler.static_check ~exec:execute_once ?checker ?flags p

  module StrSet = Elpi_util.StrSet

  type flags = Elpi_compiler.flags = {
    defined_variables : StrSet.t;
    allow_untyped_builtin : bool;
  }
  let default_flags = Elpi_compiler.default_flags
  let link ?flags x =
    Elpi_compiler.executable_of_query ?flags x

end

module Execute = struct
  type outcome = Elpi_data.outcome =
    Success of Data.solution | Failure | NoMoreSteps
  let once ?max_steps p = 
    let module R = (val !r) in let open R in
    execute_once ?max_steps p     
  let loop p ~more ~pp =
    let module R = (val !r) in let open R in
    execute_loop p ~more ~pp

end

module Pp = struct
  let term f t = (* XXX query depth *)
    let module R = (val !r) in let open R in
    R.Pp.uppterm 0 [] 0 [||] f t

  let constraints f c =
    let module R = (val !r) in let open R in
    Elpi_util.pplist ~boxed:true R.pp_stuck_goal "" f c

  let custom_constraints = Elpi_data.CustomConstraint.pp

  let query f c =
    let module R = (val !r) in let open R in
    Elpi_compiler.pp_query (fun ~depth -> R.Pp.uppterm depth [] 0 [||]) f c

  module Ast = struct
    let program = Elpi_ast.pp_program
  end
end

(****************************************************************************)

module Extend = struct

  module CData = Elpi_util.CData

  module Data = struct
    include Elpi_data
    type suspended_goal = { 
      context : hyps;
      goal : int * term
    }
    let constraints = Elpi_util.map_filter (function
      | { kind = Constraint { cdepth; conclusion; context } } ->
          Some { context ; goal = (cdepth, conclusion) }
      | _ -> None)
  end

  module Compile = struct
    module State = Elpi_data.CompilerState
    include Elpi_compiler
    let term_at ~depth (_,x) = term_of_ast ~depth x
    let query = query_of_term
  end

  module BuiltInPredicate = struct
    exception No_clause = Elpi_data.No_clause
    include Elpi_data.Builtin

    let data_of_cdata ~name:ty ?(constants=Data.Constants.Map.empty)
      { CData.cin; isc; cout }
    =
      let to_term x = Data.CData (cin x) in
      let of_term ~depth t =
        let module R = (val !r) in let open R in
        match R.deref_head ~depth t with
        | Data.CData c when isc c -> Data (cout c)
        | (Data.UVar _ | Data.AppUVar _) as x -> Flex x
        | Data.Discard -> Discard
        | Data.Const i as t when i < 0 ->
            begin try Data (Data.Constants.Map.find i constants)
            with Not_found -> raise (TypeErr t) end
        | t -> raise (TypeErr t) in
      { to_term; of_term; ty }

    let int    = data_of_cdata ~name:"int" Elpi_data.C.int
    let float  = data_of_cdata ~name:"float" Elpi_data.C.float
    let string = data_of_cdata ~name:"string" Elpi_data.C.string
    let poly ty =
      let to_term x = x in
      let of_term ~depth t =
        let module R = (val !r) in let open R in
        match R.deref_head ~depth t with
        | Data.Discard -> Discard
        | x -> Data x in
      { to_term; of_term; ty }
    let any = poly "any"
    let list d =
      let to_term l =
        let module R = (val !r) in let open R in
        list_to_lp_list (List.map d.to_term l) in
      let of_term ~depth t =
        let module R = (val !r) in let open R in
        match R.deref_head ~depth t with
        | Data.Discard -> Discard
        | (Data.UVar _ | Data.AppUVar _) as x -> Flex x
        | _ ->
            Data (List.fold_right (fun t l ->
              match d.of_term ~depth t with
              | Data x -> x :: l
              | _ -> raise (TypeErr t))
                (lp_list_to_list ~depth t) []) in
      { to_term; of_term; ty = "list " ^ d.ty }

    let builtin_of_declaration x = x

    module Notation = struct

      let (?:) a = (), Some a
      let (?::) a b = ((), Some a), Some b
      let (?:::) a b c = (((), Some a), Some b), Some c
      let (?::::) a b c d = ((((), Some a), Some b), Some c), Some d

    end
  end

  module CustomConstraint = Elpi_data.CustomConstraint

  module CustomFunctor = struct
  
    let declare_backtick name f =
      Elpi_data.CustomFunctorCompilation.declare_backtick_compilation name
        (fun s x -> f s (Elpi_ast.Func.show x))

    let declare_singlequote name f =
      Elpi_data.CustomFunctorCompilation.declare_singlequote_compilation name
        (fun s x -> f s (Elpi_ast.Func.show x))

  end

  module Utils = struct
    let lp_list_to_list ~depth t =
      let module R = (val !r) in let open R in
      lp_list_to_list ~depth t
            
    let list_to_lp_list tl =
      let module R = (val !r) in let open R in
      list_to_lp_list tl
   
    let deref_uv ~from ~to_ ~ano:nargs t =
      let module R = (val !r) in let open R in
      deref_uv ~from ~to_ nargs t

    let deref_appuv ~from ~to_:constant ~args t =
      let module R = (val !r) in let open R in
      deref_appuv ~from ~to_:constant args t

    let rec deref_head on_arg ~depth = function
      | Data.UVar ({ Data.contents = t }, from, ano)
        when t != Data.Constants.dummy ->
         deref_head on_arg ~depth (deref_uv ~from ~to_:depth ~ano t)
      | Data.AppUVar ({Data.contents = t}, from, args)
        when t != Data.Constants.dummy ->
         deref_head on_arg ~depth (deref_appuv ~from ~to_:depth ~args t)
      | Data.App(c,x,xs) when not on_arg ->
         Data.App(c,deref_head true ~depth x,List.map (deref_head true ~depth) xs)
      | x -> x

    let deref_head ~depth t = deref_head false ~depth t

    let move ~from ~to_ t =
      let module R = (val !r) in let open R in
      R.hmove ~from ~to_ ?avoid:None t
   
    let is_flex ~depth t =
      let module R = (val !r) in let open R in
      is_flex ~depth t

    let error = Elpi_util.error
    let type_error = Elpi_util.type_error
    let anomaly = Elpi_util.anomaly
    let warn = Elpi_util.warn

    let clause_of_term ?name ?graft ~depth term =
      let module Ast = Elpi_ast in
      let module R = (val !r) in let open R in
      let rec aux d ctx t =
        match deref_head ~depth:d t with       
        | Data.Const i when i >= 0 && i < depth ->
            error "program_of_term: the term is not closed"
        | Data.Const i when i < 0 ->
            Ast.mkCon (Data.Constants.show i)
        | Data.Const i -> Elpi_util.IntMap.find i ctx
        | Data.Lam t ->
            let s = "x" ^ string_of_int d in
            let ctx = Elpi_util.IntMap.add d (Ast.mkCon s) ctx in
            Ast.mkLam s (aux (d+1) ctx t)
        | Data.App(c,x,xs) ->
            let c = aux d ctx (Data.Constants.of_dbl c) in
            let x = aux d ctx x in
            let xs = List.map (aux d ctx) xs in
            Ast.mkApp (c :: x :: xs)
        | (Data.Arg _ | Data.AppArg _) -> assert false
        | Data.Cons(hd,tl) ->
            let hd = aux d ctx hd in
            let tl = aux d ctx tl in
            Ast.mkSeq [hd;tl]
        | Data.Nil -> Ast.mkNil
        | Data.Builtin(c,xs) ->
            let c = aux d ctx (Data.Constants.of_dbl c) in
            let xs = List.map (aux d ctx) xs in
            Ast.mkApp (c :: xs)
        | Data.CData x -> Ast.mkC x
        | (Data.UVar _ | Data.AppUVar _) ->
            error "program_of_term: the term contains uvars"
        | Data.Discard -> Ast.mkCon "_"
      in
      let attributes =
        (match name with Some x -> [Ast.Name x] | None -> []) @
        (match graft with
         | Some (`After,x) -> [Ast.After x]
         | Some (`Before,x) -> [Ast.Before x]
         | None -> []) in
      [Ast.Clause {
        Ast.loc = Ploc.dummy;
        Ast.attributes;
        Ast.body = aux depth Elpi_util.IntMap.empty term;
      }]

  end

  module Pp = struct

    let term ?min_prec a b c d e f =
      let module R = (val !r) in let open R in
      R.Pp.uppterm ?min_prec a b c d e f

    let constraint_ f c = 
      let module R = (val !r) in let open R in
      R.pp_stuck_goal f c

    let list = Elpi_util.pplist

    module Raw = struct
      let term ?min_prec a b c d e f =
        let module R = (val !r) in let open R in
        R.Pp.ppterm ?min_prec a b c d e f
      let show_term = Elpi_data.show_term
    end
  end
end

module Temporary = struct

  let activate_latex_exporter = Elpi_latex_exporter.activate

end
