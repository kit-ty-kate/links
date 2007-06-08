(*pp camlp4of *)
module InContext (L : Base.Loc) =
struct
  open Base
  open Utils
  open Types
  open Camlp4.PreCast
  include Base.InContext(L)

  let classname = "Eq"

  let lprefix = "l" and rprefix = "r"

  let wildcard_failure = <:match_case< _ -> false >>

  let rec expr t = (Lazy.force obj) # expr t and rhs t = (Lazy.force obj) # rhs t
  and obj = lazy (new make_module_expr ~classname ~variant ~record ~sum ~allow_private:true)
    
  and polycase ctxt : Types.tagspec -> Ast.match_case = function
    | Tag (name, None) -> <:match_case< `$name$, `$name$ -> true >>
    | Tag (name, Some e) -> <:match_case< 
        `$name$ l, `$name$ r -> 
           let module M = $expr ctxt e$ in M.eq l r >>
    | Extends t -> 
       let lpatt, lguard, lcast = cast_pattern ctxt ~param:"l" t in
        let rpatt, rguard, rcast = cast_pattern ctxt ~param:"r" t in
          <:match_case<
            ($lpatt$, $rpatt$) when $lguard$ && $rguard$ ->
            let module M = $expr ctxt t$ in 
              M.eq $lcast$ $rcast$ >>

  and case ctxt : Types.summand -> Ast.match_case = 
    fun (name,args) ->
      match args with 
        | [] -> <:match_case< ($uid:name$, $uid:name$) -> true >>
        | _ -> 
            let nargs = List.length args in
            let lpatt, lexpr = tuple ~param:"l" nargs
            and rpatt, rexpr = tuple ~param:"r" nargs in
              <:match_case<
                ($uid:name$ $lpatt$, $uid:name$ $rpatt$) ->
                   let module M = $expr ctxt (`Tuple args)$ in
                     M.eq $lexpr$ $rexpr$ >> 
              
  and field ctxt : Types.field -> Ast.expr = function
    | (name, ([], t), `Immutable) -> <:expr<
        let module M = $expr ctxt t$ in
          M.eq $lid:lprefix ^ name$ $lid:rprefix ^ name$ >>
    | (_, _, `Mutable) -> assert false
    | f -> raise (Underivable ("Eq cannot be derived for record types with polymorphic fields")) 

  and sum ?eq ctxt decl summands =
    let wildcard = match summands with [_] -> [] | _ -> [ <:match_case< _ -> false >>] in
  <:module_expr< 
      struct type a = $atype ctxt decl$
             let eq l r = match l, r with 
                          $list:List.map (case ctxt) summands @ wildcard$
  end >>

  and record ?eq ctxt decl fields = 
    if List.exists (function (_,_,`Mutable) -> true | _ -> false) fields then
       <:module_expr< struct type a = $atype ctxt decl$ let eq = (==) end >>
    else
    let lpatt = record_pattern ~prefix:"l" fields
    and rpatt = record_pattern ~prefix:"r" fields 
    and expr = 
      List.fold_right
        (fun f e -> <:expr< $field ctxt f$ && $e$ >>)
        fields
        <:expr< true >>
    in <:module_expr< struct type a = $atype ctxt decl$
                             let eq $lpatt$ $rpatt$ = $expr$ end >>

  and variant ctxt decl (spec, tags) = 
    <:module_expr< struct type a = $atype ctxt decl$
                          let eq l r = match l, r with
                                       $list:List.map (polycase ctxt) tags$
                                       | _ -> false end >>
end

let _ = Base.register "Eq" 
  ((fun (loc, context, decls) -> 
     let module M = InContext(struct let loc = loc end) in
       M.generate ~context ~decls ~make_module_expr:M.rhs ~classname:M.classname
         ~default_module:"Eq_defaults" ()),
   (fun (loc, context, decls) -> 
      let module M = InContext(struct let loc = loc end) in
        M.gen_sigs ~context ~decls ~classname:M.classname))

