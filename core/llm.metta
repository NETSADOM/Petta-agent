; llm.metta — talking to the LLM (Gemini or any OpenAI-compatible API), in MeTTa.
;
; The LLM only PROPOSES. Every reply is parsed into an atom and checked by the
; rules below before anything else may use it. Needs core/schema.metta loaded.
; Provider choice: core/llm_client.py (PAGENT_PROVIDER = gemini | openai).
;
;   (make-plan)     ask for a plan, validate it, load it into &wm as tasks
;   (propose-next)  ask for the next step → (action T "in") | (final "a") | (ask-user "q")
;                   or (invalid ...) / (error KIND "msg")

!(import! &self "gemini.py")
!(import! &self "openai_compat.py")
!(import! &self "llm_client.py")      ; picks the provider
!(import! &self "reply_parser.py")    ; S-expression or JSON tool calls → atom
!(import! &self "prompts.py")
!(import! &self skills)
!(import! &self memory)   ; needs only schema.metta (no cycle)
!(import! &self recovery) ; needs only schema.metta (no cycle)

; ---------------- raw call ----------------
; → (ok "text") | (error KIND "message")
; The "brain" is Gemini, unless (config brain scripted) is set: then replies are
; replayed from &script — used by tests, and the rest of the pipeline is identical.
(= (ask-llm $system $prompt)
   (if (== (collapse (config-value brain)) (scripted))
       (scripted-reply $prompt)
       (py-call (llm_client.generate $system $prompt))))

; ---------------- scripted brain (for tests) ----------------
;   !(use-script ("(plan ...)" "(action ...)" "(final ...)"))
(= (add-replies $i $list)
   (if (== $list ())
       $i
       (let* (($h (car-atom $list))
              ($t (cdr-atom $list))
              ($r (add-atom &script (reply $i $h)))
              ($j (+ $i 1)))
             (add-replies $j $t))))

; NOTE: switches semantic verification OFF, since it would consume a scripted
; reply. Tests of verification turn it back on: !(set-config verify-semantic on)
(= (use-script $list)
   (let* (($old (collapse (let $a (get-atoms &script) (remove-atom &script $a))))
          ($c (set-config brain scripted))
          ($v (set-config verify-semantic off))
          ($r (add-atom &script (cursor 1))))
         (add-replies 1 $list)))

(= (scripted-reply $prompt)
   (let* (($k (match &script (cursor $c) $c))
          ($next (+ $k 1))
          ($r1 (remove-atom &script (cursor $k)))
          ($r2 (add-atom &script (cursor $next)))
          ($old (collapse (let $p (match &script (seen-prompt $x) (seen-prompt $x))
                               (remove-atom &script $p))))
          ($r3 (add-atom &script (seen-prompt $prompt)))
          ($texts (collapse (match &script (reply $k $t) $t))))
         (if (== $texts ())
             (error config "script exhausted")
             (ok (car-atom $texts)))))

; (a symbol can't be both a function and a data tag in PeTTa, hence seen-prompt)
(= (last-prompt) (match &script (seen-prompt $p) $p))

(= (temporary-error $kind) (py-call (llm_client.is_temporary $kind)))

; ---------------- reply text → atom ----------------
; → the atom, or (invalid no-expression) / (invalid unparseable)
; Accepts S-expressions and JSON tool calls (reply_parser.py translates JSON).
(= (parse-reply $text)
   (let $found (py-call (reply_parser.extract $text))
        (case $found
              (((found $s) (case (catch (sread $s))
                                 (((Error $a $b) (invalid unparseable))
                                  ($atom $atom))))
               ($none (invalid no-expression))))))

(= (is-expression $x) (== (get-metatype $x) Expression))


; ---------------- validate a proposed step ----------------
; Shape check only. An UNKNOWN tool name is a well-formed call: it goes on to
; (execute ..), which refuses it and answers (error (unknown-tool T (available ..))),
; recorded as that call's result — the model reads it next turn, like any error.
; Permission is checked later by the controller.
(= (is-symbol $x) (== (get-metatype $x) Symbol))

(= (call-ok $c)
   (if (and (is-expression $c) (== (size-atom $c) 3))
       (and (== (car-atom $c) action) (is-symbol (index-atom $c 1)))
       False))

; (actions (action T "in") ...) — several calls from one reply, run in order
(= (check-calls $p)
   (let $calls (cdr-atom $p)                ; bind first: superpose does not evaluate (gotcha 2)
        (if (== $calls ())
            (invalid bad-shape)
            (if (== (collapse (let $c (superpose $calls) (if (call-ok $c) (empty) bad))) ())
                $p
                (invalid bad-shape)))))

(= (check-proposal $p)
   (if (is-expression $p)
       (if (== $p ())
           (invalid bad-shape)
           (if (== (car-atom $p) actions) (check-calls $p) (check-one $p)))
       (invalid bad-shape)))

(= (check-one $p)
   (if (is-expression $p)
       (case $p
             (((action $tool $input) (if (is-symbol $tool) $p (invalid bad-shape)))
              ((final $answer) $p)
              ((ask-user $question) $p)
              ((task-done $id) $p)
              ((task-failed $id $why) $p)
              ((replan $why) $p)
              ((missing-capability $what) $p)
              ((learn $content $conf) $p)          ; gated later by learn-fact
              ((invalid $why) $p)
              ($other (invalid bad-shape))))
       (invalid bad-shape)))

; ---------------- validate and load a plan ----------------
;   (plan (task t1 "desc")
;         (task t2 "desc" (after t1))
;         (task t3 "desc" (after t1 t2) (uses research)))   options in any order

(= (task-id $t) (index-atom $t 1))

; options after the description: ((after t1) (uses research) ...)
(= (task-opts $t) (cdr-atom (cdr-atom (cdr-atom $t))))

(= (opt-ok $o)
   (if (is-expression $o)
       (if (== (car-atom $o) after)
           (> (size-atom $o) 1)
           (if (== (car-atom $o) uses) (== (size-atom $o) 2) False))
       False))

; dependency list of one task: () or (t1 t2 ...)
(= (task-deps $t)
   (collapse (let* (($opts (task-opts $t))
                    ($o (superpose $opts)))
                   (if (== (car-atom $o) after)
                       (let $ds (cdr-atom $o) (superpose $ds))   ; bind first: gotcha 2
                       (empty)))))

; skills a task uses: () or (research)
(= (task-uses $t)
   (collapse (let* (($opts (task-opts $t))
                    ($o (superpose $opts)))
                   (if (== (car-atom $o) uses) (index-atom $o 1) (empty)))))

(= (task-shape-ok $t)
   (if (and (is-expression $t) (>= (size-atom $t) 3))
       (if (== (car-atom $t) task)
           (== (collapse (let* (($opts (task-opts $t)) ($o (superpose $opts)))
                               (if (opt-ok $o) (empty) bad)))
               ())
           False)
       False))

; A (uses X) naming no usable skill (unknown, missing tools, or a TOOL name —
; smaller models mix them up) is ignored when the plan is loaded: the task
; itself is still fine, and rejecting the whole plan would only cost a turn.
(= (usable-skill $s) (and (skill-known $s) (skill-available $s)))

(= (plan-tasks $p) (cdr-atom $p))
(= (plan-ids $p) (map-atom (plan-tasks $p) $t (task-id $t)))

; every dependency must name a task in the same plan
; (an unknown id would otherwise look "not failed" forever)
(= (deps-known $p)
   (let $ids (plan-ids $p)
        (== (collapse (let* (($tasks (plan-tasks $p))
                             ($t (superpose $tasks))
                             ($deps (task-deps $t))
                             ($d (superpose $deps)))
                            (if (is-member $d $ids) (empty) $d)))
            ())))

(= (check-plan $p)
   (if (and (is-expression $p) (== (car-atom $p) plan))
       (let $tasks (plan-tasks $p)
            (if (== $tasks ())
                (invalid empty-plan)
                (if (== (collapse (let $t (superpose $tasks)
                                       (if (task-shape-ok $t) (empty) bad)))
                        ())
                    (if (== (size-atom (unique-atom (plan-ids $p))) (size-atom $tasks))
                        (if (deps-known $p) $p (invalid unknown-dependency))
                        (invalid duplicate-ids))
                    (invalid bad-task))))
       (invalid not-a-plan)))

; Clear old tasks, then add the plan's tasks and dependencies to &wm.
(= (clear-tasks)
   (collapse (superpose ((let $t (match &wm (task $i $d $s) (task $i $d $s)) (remove-atom &wm $t))
                         (let $t (match &wm (depends $a $b) (depends $a $b)) (remove-atom &wm $t))
                         (let $t (match &wm (task-skill $a $b) (task-skill $a $b)) (remove-atom &wm $t))))))

(= (load-task $t)
   (let* (($id (task-id $t))
          ($r (add-task $id (index-atom $t 2)))
          ($deps (task-deps $t))
          ($d1 (collapse (let $d (superpose $deps) (add-dependency $id $d))))
          ($uses (task-uses $t))
          ($s1 (collapse (let $s (superpose $uses)
                              (if (usable-skill $s) (add-atom &wm (task-skill $id $s)) (empty))))))
         $id))

(= (load-plan $p)
   (let* (($cleared (clear-tasks))
          ($tasks (plan-tasks $p))
          ($added (collapse (let $t (superpose $tasks) (load-task $t)))))
         (size-atom $tasks)))

; ---------------- context ----------------
; What the LLM sees (plan-request / act-request) is built in core/context.metta.
; Imported HERE: after its dependencies above, before make-plan uses it.
!(import! &self context)

; ---------------- the two calls ----------------
(= (make-plan)
   (let $r (ask-llm (py-call (prompts.plan_system)) (plan-request))
        (case $r
              (((ok $text)
                  (let $p (check-plan (parse-reply $text))
                       (if (== (car-atom $p) invalid) $p (planned (load-plan $p)))))
               ($err $err)))))

(= (propose-next)
   (let $r (ask-llm (py-call (prompts.act_system)) (act-request))
        (case $r
              (((ok $text) (check-proposal (parse-reply $text)))
               ($err $err)))))

