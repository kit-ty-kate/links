open Cohttp
open Cohttp_lwt_unix
open Lwt
open ProcessTypes
open Utility
open Webserver_types

let jslibdir : string Settings.setting = Settings.add_string("jslibdir", "", `User)
let host_name = Settings.add_string ("host", "0.0.0.0", `User)
let port = Settings.add_int ("port", 8080, `User)


module Trie =
struct
  type ('a, 'b) t =
    | Trie of 'b option * ('a * ('a, 'b) t) list

  let empty : ('a, 'b) t = Trie (None, [])

  let rec transform : 'a list -> ('b -> 'b) -> 'b -> ('a, 'b) t -> ('a, 'b) t =
    fun key xf b trie ->
    let rec down key (Trie (here, children)) =
      match key, here with
      | [], None -> Trie (Some b, children)
      | [], Some b' -> Trie (Some (xf b'), children)
      | hk :: tk, _ ->
         let rec right = function
           | [] -> [hk, transform tk xf b empty]
           | ((hc, child) :: tc) ->
              if hk = hc then
                (hc, down tk child) :: tc
              else
                (hc, child) :: right tc in
         Trie (here, right children) in
    down key trie

  (* This has ended up being remarkably specialized *)
  let rec longest_match : 'a list -> ('a, 'b) t -> ('a list * 'b) list =
    fun key (Trie (here, children)) ->
    match key, here with
    | [], None -> []
    | [], Some v -> [key, v]
    | hk :: tk, _ ->
       let rec right = function
         | [] -> begin
             match here with
             | None -> []
             | Some v -> [key, v]
           end
         | ((hc, child) :: tc) ->
            if hk = hc then
              match here with
              | None -> longest_match tk child
              | Some v -> longest_match tk child @ [key, v]
            else
              right tc in
       right children
end

module rec Webserver : WEBSERVER =
struct

  module Eval = Evalir.Eval(Webserver)
  module Webif = Webif.WebIf(Webserver)

  type path = string
  type mime_type = (string * string)
  type static_resource = path * mime_type list
  type request_handler_fn = Value.env * Value.t

  type provider = (static_resource, request_handler_fn) either option
  type providers = { as_directory: provider; as_page: provider }  (* Really, at least one should be Some *)
  type routing_table = (string, providers) Trie.t

  let rt : routing_table ref = ref Trie.empty
  let env : (Value.env * Ir.var Env.String.t * Types.typing_environment) ref =
    ref (Value.Env.empty, Env.String.empty, Types.empty_typing_environment)
  let prelude : Ir.binding list ref = ref []
  let globals : Ir.binding list ref = ref []

  let set_prelude bs =
    prelude := bs
  let init some_env some_globals =
    env := some_env;
    globals := some_globals;
    ()

  let add_route is_directory path thread_starter =
    rt := Trie.transform
            (Str.split (Str.regexp "/") path)
            (fun p -> if is_directory then
                        {p with as_directory = Some thread_starter}
                      else
                        {p with as_page = Some thread_starter})
            (if is_directory then
               { as_directory = Some thread_starter; as_page = None }
             else
               { as_directory = None; as_page = Some thread_starter })
            !rt

  let extract_client_id cgi_args =
    Utility.lookup "__client_id" cgi_args

  let get_client_id_or_die cgi_args =
    match extract_client_id cgi_args with
      | Some client_id ->
          Debug.print ("Found client ID: " ^ client_id);
          let decoded_client_id = Utility.base64decode client_id in
          Debug.print ("Decoded client ID: " ^ decoded_client_id);
          Lwt.return (ClientID.of_string decoded_client_id)
      | None -> failwith "Client ID expected but not found."


  let get_or_make_client_id cgi_args =
    if (Webif.should_contain_client_id cgi_args) then
      get_client_id_or_die cgi_args
    else
      ClientID.create ()

  let start tl_valenv =
    let is_prefix_of s t = String.length s <= String.length t && s = String.sub t 0 (String.length s) in
    let ( / ) = Filename.concat in

    let parse_post_body s =
      let assocs = split '&' s in
      let one_assoc s =
        try
          let i = String.index s '=' in
          String.sub s 0 i,
          Cgi.decode (String.sub s (succ i) (String.length s - i - 1))
        with
        | Not_found -> s,"" in
      List.map one_assoc assocs in

    let callback rt render_cont _conn req body =
      let req_hs = Request.headers req in
      let content_type = Header.get req_hs "content-type" in
      Cohttp_lwt_body.to_string body >>= fun body_string ->

      let cgi_args : (string * string) list =
        match Request.meth req, content_type with
        | `POST, Some content_type when string_starts_with content_type "multipart/form-data" ->
           List.map (fun (name, { Multipart.value=value; _ }) -> (name, value))
                    (Multipart.parse_multipart_args content_type body_string)
        | `POST, _ ->
           parse_post_body body_string
        | `GET, _ ->
           List.map (fun (k, vs) -> (k, String.concat "," vs)) (Uri.query (Request.uri req))
        | _, _ -> [] (* FIXME: should possibly do something else here *) in

      (* Add headers as cgi args. Is this really what we want to do? *)
      let cgi_args = cgi_args @ Header.to_list (Request.headers req) in
      let cookies = Cohttp.Cookie.Cookie_hdr.extract (Request.headers req) in
      Debug.print (Printf.sprintf "%n cgi_args:" (List.length cgi_args));
      List.iter (fun (k, v) -> Debug.print (Printf.sprintf "   %s: \"%s\"" k v)) cgi_args;
      let path = Uri.path (Request.uri req) in

      (* Precondition: valenv has been initialised with the correct request data *)
      let run_page (valenv, v) () =
        let cid = RequestData.get_client_id (Value.Env.request_data valenv) in
        Eval.apply (render_cont ()) valenv
        (v, [`String path; `SpawnLocation (`ClientSpawnLoc cid)]) >>= fun (valenv, v) ->
          let page = Irtojs.generate_real_client_page
                       ~cgi_env:cgi_args
                       (Lib.nenv, Lib.typing_env)
                       (* hypothesis: local definitions shouldn't matter,
                        * they should all end up in valenv... *)
                       (!prelude @ !globals)
                       (valenv, v)
          in
        Lwt.return ("text/html", page) in

      let render_servercont_cont valenv v =
        Irtojs.generate_real_client_page
          ~cgi_env:cgi_args
          (Lib.nenv, Lib.typing_env)
          (!prelude @ !globals)
          (valenv, v) in

      let serve_static base uri_path mime_types =
          let fname =
            let fname = base / uri_path in
            let n = String.length fname in
            if n > 1 && String.get fname (n-1) = '/' then
              fname / "index.html"
            else
              base / uri_path in

          let headers =
            (* Filename.extension not defined until 4.04, because who would want such a thing *)
            let rec loop = function
              | [] -> Cohttp.Header.init ()
              | ((ext, content_type) :: rest) ->
                 if Filename.check_suffix fname ("." ^ ext) then
                   Cohttp.Header.init_with "content-type" content_type
                 else
                   loop rest in
            loop mime_types in
          Debug.print (Printf.sprintf "Responding to static request;\n    Requested: %s\n    Providing: %s\n" path fname);
          Server.respond_file ~headers ~fname () in

      let route rt =
        let rec up = function
          | [], _ -> Server.respond_string ~status:`Not_found ~body:"<html><body><h1>Nope</h1></body></html>" ()
          | ([] as remaining, { as_page = Some (Left (file_path, mime_types)); _ }) :: _, true
          | (remaining, { as_directory = Some (Left (file_path, mime_types)); _ }) :: _, true ->
             serve_static file_path (String.concat "/" remaining) mime_types
          | (remaining, { as_directory = Some (Left (file_path, mime_types)); _ }) :: _, false ->
             serve_static file_path (String.concat "/" remaining / "index.html") mime_types
          | ([], { as_page = Some (Right (valenv, v)); _ }) :: _, true
          | (_, { as_directory = Some (Right (valenv, v)); _ }) :: _, _ ->
             let (_, nenv, tyenv) = !env in
             get_or_make_client_id cgi_args >>= fun (cid) ->
             let req_data = RequestData.new_request_data cgi_args cookies cid in
             let req_env = Value.Env.set_request_data (Value.Env.shadow tl_valenv ~by:valenv) req_data in
             Webif.do_request
               (req_env, nenv, tyenv)
               cgi_args
               (run_page (req_env, v))
               (render_cont ())
               (render_servercont_cont req_env)
               (fun hdrs bdy -> Lib.cohttp_server_response hdrs bdy req_data)
          | _ :: t, path_is_file -> up (t, path_is_file) in
        up (Trie.longest_match (Str.split (Str.regexp "/") path) !rt, path.[String.length path - 1] <> '/') in

      if is_prefix_of (Settings.get_value Basicsettings.Js.lib_url) path then
        let liburl_length = String.length (Settings.get_value Basicsettings.Js.lib_url) in
        let uri_path = (String.sub path liburl_length (String.length path - liburl_length)) in
        let linkslib = match Settings.get_value jslibdir with
          | "" ->
             begin
               (match Utility.getenv "LINKS_LIB" with
                | None -> Filename.dirname Sys.executable_name
                | Some path -> path) / "lib" / "js"
             end
          | s -> s in
        serve_static linkslib uri_path []
      else
        route rt in

    let start_server host port rt =

      let render_cont () =
        let (_, nenv, {Types.tycon_env = tycon_env; _ }) = !env in
        let _, x = Var.fresh_global_var_of_type (Instantiate.alias "Page" [] tycon_env) in
        let render_page = Env.String.lookup nenv "renderPage" in
        let tail = `Apply (`Variable render_page, [`Variable x]) in
        Hashtbl.add Tables.scopes x `Global;
        Hashtbl.add Tables.cont_defs x ([], tail);
        Hashtbl.add Tables.cont_vars x IntSet.empty;
        let frame = Value.Continuation.Frame.make `Global x Value.Env.empty ([], tail) in
        Value.Continuation.(frame &> empty)
      in

      Conduit_lwt_unix.init ~src:host () >>= fun ctx ->
      let ctx = Cohttp_lwt_unix_net.init ~ctx () in
      Debug.print ("Starting server (2)?\n");
      Server.create ~ctx ~mode:(`TCP (`Port port)) (Server.make ~callback:(callback rt render_cont) ()) in

    Debug.print ("Starting server?\n");
    Lwt.async_exception_hook :=
      (fun exn -> Debug.print ("Caught asynchronous exception: " ^ (Printexc.to_string exn)));
    Settings.set_value Basicsettings.web_mode true;
    Settings.set_value webs_running true;
    start_server (Settings.get_value host_name) (Settings.get_value port) rt
end
