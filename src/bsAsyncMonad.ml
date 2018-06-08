module type Async_t = sig
  type 'a t
  val return : 'a -> 'a t
  val fail : exn -> 'a t
  val compose : ?noStack:bool -> 'a t -> ('a -> 'b t) -> 'b t
  val (>>)    : 'a t -> ('a -> 'b t) -> 'b t
  val catch  : ?noStack:bool -> 'a t -> (exn -> 'a t) -> 'a t
  val (||>)  : 'a t -> (exn -> 'a t) -> 'a t
  val pipe : ?noStack:bool -> 'a t -> ('a -> 'b) -> 'b t
  val (>|) : 'a t -> ('a -> 'b) -> 'b t
  val ensure : ?noStack:bool -> 'a t -> (unit -> unit t) -> 'a t
  val (&>)   : 'a t -> (unit -> unit t) -> 'a t
  val discard : 'a t -> unit t
  val repeat : (unit -> bool t) -> (unit -> unit t) -> unit t
  val fold_lefta : ?concurrency:int -> ('a -> 'b -> 'a t) -> 'a t -> 'b array -> 'a t
  val fold_left  : ?concurrency:int -> ('a -> 'b -> 'a t) -> 'a t -> 'b list -> 'a t
  val fold_lefti : ?concurrency:int -> ('a -> int -> 'b -> 'a t) -> 'a t -> 'b list -> 'a t
  val itera  : ?concurrency:int -> ('a -> unit t) -> 'a array -> unit t
  val iter   : ?concurrency:int -> ('a -> unit t) -> 'a list -> unit t
  val iteri  : ?concurrency:int -> (int -> 'a -> unit t) -> 'a list -> unit t
  val mapa : ?concurrency:int -> ('a -> 'b t) -> 'a array -> 'b array t
  val map  : ?concurrency:int -> ('a -> 'b t) -> 'a list -> 'b list t
  val mapi : ?concurrency:int -> (int -> 'a -> 'b t) -> 'a list -> 'b list t
  val seqa : ?concurrency:int -> unit t array -> unit t
  val seq  : ?concurrency:int -> unit t list -> unit t
  val execute : ?exceptionHandler:(exn->unit) -> 'a t -> ('a -> unit) -> unit
  val finish  : ?exceptionHandler:(exn->unit) -> unit t -> unit
end

module Callback = struct
  type error  = exn Js.nullable
  type 'a callback = error -> 'a -> unit [@bs]
  (* A computation takes a callback and executes it
     either with an error or with a result of type 'a. *)
  type 'a t = 'a callback -> unit

  (* Computation that returns x as a value. *)
  let return x cb =
    cb Js.Nullable.null x [@bs]

  (* Computation that returns an error. *)
  let fail exn cb =
    cb (Js.Nullable.return exn) (Obj.magic Js.Nullable.null) [@bs]

  external setTimeout : (unit -> unit [@bs]) -> float -> unit = "" [@@bs.val]

  exception Error of exn

  (* Pipe current's result into next. *)
  let compose ?(noStack=false) current next cb =
    let fn = fun [@bs] err ret ->
      match Js.toOption err with
        | Some exn -> fail exn cb
        | None     ->
           let next = fun [@bs] () ->
             try
               let next =
                 try
                   next ret
                 with exn -> raise (Error exn)
               in
               next cb
             with Error exn -> fail exn cb
           in
           if noStack then
             setTimeout next 0.
           else
             next () [@bs]
    in
    current fn

  let (>>) = fun a b ->
    compose a b

  let on_next ~noStack next =
    if noStack then
      setTimeout next 0.
    else
      next () [@bs]

  (* Catch exception. *)
  let catch ?(noStack=false) current catcher cb =
    let cb = fun [@bs] err ret ->
      match Js.toOption err with
        | Some exn ->
            on_next ~noStack (fun [@bs] () ->
              catcher exn cb)
        | None     ->
            on_next ~noStack (fun [@bs] () ->
              cb err ret [@bs])
    in
    current cb

  let (||>) = fun a b ->
    catch a b

  let pipe ?(noStack=false) current fn cb =
    current (fun [@bs] err ret ->
      match Js.toOption err with
        | Some exn ->
          on_next ~noStack (fun [@bs] () ->
            fail exn cb)
        | None ->
          on_next ~noStack (fun [@bs] () ->
            try
              let ret =
                try
                  fn ret
                with exn -> raise (Error exn)
              in
              return ret cb
            with Error exn ->
              fail exn cb))

  let (>|) = fun a b ->
    pipe a b

  let ensure ?(noStack=false) current ensure cb =
    current (fun [@bs] err ret ->
      on_next ~noStack (fun [@bs] () ->
        ensure () (fun [@bs] _ _ ->
          cb err ret [@bs])))

  let (&>) = fun a b ->
    ensure a b

  let discard fn cb =
    fn (fun [@bs] err _ ->
      cb err () [@bs])

  let repeat condition computation cb =
    let rec exec () =
      condition () (fun [@bs] err ret ->
        match Js.Nullable.test err, ret with
          | true, true ->
              computation () (fun [@bs] err ret ->
                if Js.Nullable.test err then
                  cb err ret [@bs]
                else
                  setTimeout (fun [@bs] () ->
                    exec ()) 0.)
          | _ -> cb err () [@bs])
    in
    setTimeout (fun [@bs] () ->
      exec ()) 0.

  let itera ?(concurrency=1) fn a cb =
    let total = Array.length a in
    let executed = ref 0 in
    let failed = ref false in
    let rec process () =
      let on_done () =
        incr executed;
        match !failed, !executed with
          | true, _ -> ()
          | false, n when n = total ->
              return () cb
          | _ ->
              setTimeout (fun [@bs] () -> process ()) 0.
      in
      match Js.Array.shift a with
        | Some v ->
            fn v (fun [@bs] err () ->
              match Js.toOption err with
                | Some exn ->
                    if not !failed then
                      fail exn cb;
                    failed := true
                | None -> on_done ())
        | None -> ()
    in
    for _ = 1 to min total concurrency do
      setTimeout (fun [@bs] () -> process ()) 0.
    done

  let iter ?concurrency fn l =
    itera ?concurrency fn (Array.of_list l)

  let fold_lefta ?concurrency fn a ba =
    let cur = ref a in
    let fn b =
      !cur >> fun a ->
        cur := fn a b;
        return ()
    in
    itera ?concurrency fn ba >> fun () ->
      !cur

  let fold_left ?concurrency fn cur l =
    fold_lefta ?concurrency fn cur (Array.of_list l)

  let fold_lefti ?concurrency fn cur l =
    let l =
      List.mapi (fun idx el ->
        (idx,el)) l
    in
    let fn cur (idx,el) =
      fn cur idx el
    in
    fold_left ?concurrency fn cur l

  let iteri ?concurrency fn l =
    let l =
      List.mapi (fun idx el ->
        (idx,el)) l
    in
    let fn (idx,el) =
      fn idx el
    in
    iter ?concurrency fn l

  let mapa ?concurrency fn a =
    let ret = [||] in
    let map v =
      fn v >> fun res ->
        ignore(Js.Array.push res ret);
        return ()
    in
    itera ?concurrency map a >> fun () ->
      return ret

  let map ?concurrency fn l =
    mapa ?concurrency fn (Array.of_list l) >> fun ret ->
      return (Array.to_list ret)

  let mapi ?concurrency fn l =
    let l =
      List.mapi (fun idx el ->
        (idx,el)) l
    in
    let fn (idx,el) = 
      fn idx el
    in
    map ?concurrency fn l

  let seqa ?concurrency a =
    itera ?concurrency (fun v -> v >> return) a

  let seq ?concurrency l =
    seqa ?concurrency (Array.of_list l)

  let execute ?(exceptionHandler=fun exn -> raise exn) t cb =
    t (fun [@bs] err ret ->
      match Js.toOption err with
        | None -> cb ret
        | Some exn -> exceptionHandler exn)

  let finish ?exceptionHandler t =
    execute ?exceptionHandler t (fun _ -> ())

  let from_promise p = fun cb ->
    let on_success ret =
      return ret cb;
      Js.Promise.resolve ret
    in
    (* There's an inherent conflict here between dynamically typed JS world
     * and statically typed BS/OCaml world. The promise API says that the
     * value returned by the onError handler determines the value or error
     * with which the promise gets resolved.
     * In JS world, that means that you can just do console.log and the promise
     * gets resolved with null/unit whatever.
     * But in statically typed world the promise is of type 'a and needs a
     * type 'a to resolve and since this code is generic, we have no idea how
     * to produce a value of type 'a. Also, if we return the original promise,
     * the runtime thinks that we're not handling errors and complains about it.
     * Thus: Obj.magic. 😳 *)
    let on_error err =
      fail (Obj.magic err) cb;
      Js.Promise.reject (Obj.magic err)
    in
    ignore(Js.Promise.then_ on_success p |> Js.Promise.catch on_error)

  let to_promise fn =
    Js.Promise.make (fun ~resolve ~reject ->
      fn (fun [@bs] err ret ->
        match Js.toOption err with
          | Some exn -> reject exn [@bs]
          | None -> resolve ret [@bs]))
end

module Promise = struct
  type 'a t = 'a Js.Promise.t
  let return = Js.Promise.resolve
  let fail = Js.Promise.reject
  let compose ?noStack:_ p fn =
    Js.Promise.then_ fn p
  let (>>) = fun p fn ->
    compose p fn
  let catch ?noStack:_ p fn =
    Js.Promise.catch (fun exn ->
      fn (Obj.magic exn)) p
  let (||>) = fun p fn ->
    catch p fn
  let pipe ?noStack:_ p fn =
    compose p (fun v ->
      return (fn v))
  let (>|) = fun p fn ->
    pipe p fn
  let ensure ?noStack:_ p fn =
    let c =
      Callback.from_promise p
    in
    let c =
      Callback.ensure ~noStack:true c (fun () ->
        Callback.from_promise (fn ()))
    in
    Callback.to_promise c
  let (&>) = fun p fn ->
    ensure p fn
  let discard p =
    p >> (fun _ -> return ())
  let repeat cond body =
    let cond () =
      Callback.from_promise (cond ())
    in
    let body () =
      Callback.from_promise (body ())
    in
    let c =
      Callback.repeat cond body
    in
    Callback.to_promise c
  let fold_lefta ?concurrency fn p a =
    let fn x y =
      Callback.from_promise (fn x y)
    in
    let c =
      Callback.from_promise p
    in
    Callback.to_promise
      (Callback.fold_lefta ?concurrency fn c a)
  let fold_left ?concurrency fn p l =
    fold_lefta ?concurrency fn p (Array.of_list l)
  let fold_lefti ?concurrency fn p l =
    let fn x pos y =
      Callback.from_promise (fn x pos y)
    in
    let c =
      Callback.from_promise p
    in
    Callback.to_promise
      (Callback.fold_lefti ?concurrency fn c l)
  let itera ?concurrency fn a =
    let fn x =
      Callback.from_promise (fn x)
    in
    Callback.to_promise
      (Callback.itera ?concurrency fn a)
  let iter ?concurrency fn l =
    itera ?concurrency fn (Array.of_list l)
  let iteri ?concurrency fn l =
    let fn pos x =
      Callback.from_promise (fn pos x)
    in
    Callback.to_promise
      (Callback.iteri ?concurrency fn l)
  let mapa ?concurrency fn a =
    let fn x =
      Callback.from_promise (fn x)
    in
    Callback.to_promise
      (Callback.mapa ?concurrency fn a)
  let map ?concurrency fn l =
    mapa ?concurrency fn (Array.of_list l) >> fun a ->
      return (Array.to_list a)
  let mapi ?concurrency fn l =
    let fn pos x =
      Callback.from_promise (fn pos x)
    in
    Callback.to_promise
      (Callback.mapi ?concurrency fn l)
  let seqa ?concurrency a =
    let a =
      Array.map Callback.from_promise a
    in
    Callback.to_promise
      (Callback.seqa ?concurrency a)
  let seq ?concurrency l =
    seqa ?concurrency (Array.of_list l)
  let execute ?exceptionHandler p cb =
    Callback.execute ?exceptionHandler
      (Callback.from_promise p) cb
  let finish ?exceptionHandler p =
    execute ?exceptionHandler p (fun () -> ())
end