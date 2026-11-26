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
; The "brain" is the configured LLM, unless (config brain scripted) is set: then replies are
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
; a batch item: a call, (task-done t1 ...) closing tasks in the same turn, or
; (final "answer") — it ends the batch (agent.metta run-calls)
(= (batch-item-ok $c)
   (if (call-ok $c)
       True
       (if (and (is-expression $c) (and (> (size-atom $c) 1) (== (car-atom $c) task-done)))
           (== (task-ids-ok $c) $c)
           (if (is-expression $c)
               (and (== (car-atom $c) final) (== (size-atom $c) 2))
               False))))
(= (check-calls $p)
   (let $calls (cdr-atom $p)                ; bind first: superpose does not evaluate (gotcha 2)
        (if (== $calls ())
            (invalid bad-shape)
            (if (== (collapse (let $c (superpose $calls) (if (batch-item-ok $c) (empty) bad))) ())
                $p
                (invalid bad-shape)))))

; (task-done t1 t2 ...): every id must be a symbol
(= (task-ids-ok $p)
   (let $ids (cdr-atom $p)
        (if (== (collapse (let $id (superpose $ids) (if (is-symbol $id) (empty) bad))) ())
            $p
            (invalid bad-shape))))

; (action write-file "PATH" "CONTENT") → (action write-file "{\"path\": .., \"content\": ..}")
; The JSON input puts JSON inside a MeTTa string: every quote in the content
; needs TWO levels of escaping, and one slip in a long summary lost the whole
; reply (seen: a 3-paper summary refused as unusable). Two plain strings need
; one level, like a final. Also inside a batch.
(= (normalize-call $c)
   (if (and (is-expression $c) (== (size-atom $c) 4))
       (if (and (== (car-atom $c) action) (== (index-atom $c 1) write-file))
           (action write-file (as-string (py-call (reply_parser.write_file_input (index-atom $c 2) (index-atom $c 3)))))
           $c)
       $c))

(= (normalize-proposal $p)
   (if (and (is-expression $p) (not (== $p ())))
       (if (== (car-atom $p) actions)
           (cons-atom actions (map-atom (cdr-atom $p) $c (normalize-call $c)))
           (normalize-call $p))
       $p))

(= (check-proposal $p) (check-normalized (normalize-proposal $p)))

(= (check-normalized $p)
   (if (is-expression $p)
       (if (== $p ())
           (invalid bad-shape)
           (if (== (car-atom $p) actions) (check-calls $p) (check-one $p)))
       (invalid bad-shape)))

(= (check-one $p)
   (if (is-expression $p)
       (if (and (== (car-atom $p) task-done) (> (size-atom $p) 2))
           (task-ids-ok $p)                      ; (task-done t1 t2 ...)
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
              ($other (invalid bad-shape)))))
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

; ---------------- dependencies must form a DAG ----------------
; (after t1) inside t1, or t1 → t2 → t1: such tasks could never become ready,
; and the run would stall on them. Detected here, before anything is loaded.
;   dep map: ((t1 ()) (t2 (t1)) ...)
(= (dep-map $p) (map-atom (plan-tasks $p) $t ((task-id $t) (task-deps $t))))

(= (deps-of $id $map)
   (let $hits (collapse (let $e (superpose $map) (if (== (index-atom $e 0) $id) (index-atom $e 1) (empty))))
        (if (== $hits ()) () (car-atom $hits))))

; can $from reach $target by following dependencies? ($k bounds the depth)
(= (reaches $from $target $map $k)
   (if (<= $k 0)
       False
       (let $ds (deps-of $from $map)
            (if (== (collapse (let $d (superpose $ds) (if (== $d $target) yes (empty)))) ())
                (any-reaches $ds $target $map (- $k 1))
                True))))

(= (any-reaches $ds $target $map $k)
   (if (== $ds ())
       False
       (if (reaches (car-atom $ds) $target $map $k)
           True
           (any-reaches (cdr-atom $ds) $target $map $k))))

(= (self-dependent $p)
   (let $map (dep-map $p)
        (collapse (let $e (superpose $map)
                       (let ($id $ds) $e
                            (if (== (collapse (let $d (superpose $ds) (if (== $d $id) yes (empty)))) ())
                                (empty) $id))))))

(= (cyclic-tasks $p)
   (let* (($map (dep-map $p))
          ($n (size-atom $map))
          ($ids (plan-ids $p)))
         (collapse (let $id (superpose $ids) (if (reaches $id $id $map $n) $id (empty))))))

(= (check-deps $p)
   (let $self (self-dependent $p)
        (if (not (== $self ()))
            (invalid (self-dependency $self "a task cannot come after itself"))
            (let $cyc (cyclic-tasks $p)
                 (if (== $cyc ())
                     $p
                     (invalid (dependency-cycle $cyc "these tasks wait for each other in a circle, so none could ever start")))))))

(= (check-plan $p)
   (if (and (is-expression $p) (== (car-atom $p) plan))
       (let $tasks (plan-tasks $p)
            (if (== $tasks ())
                (invalid empty-plan)
                (if (== (collapse (let $t (superpose $tasks)
                                       (if (task-shape-ok $t) (empty) bad)))
                        ())
                    (if (== (size-atom (unique-atom (plan-ids $p))) (size-atom $tasks))
                        (if (deps-known $p) (check-deps $p) (invalid unknown-dependency))
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
; A short, single-step goal ("what is 15 percent of 2480") gets a one-task plan
; WITHOUT an LLM call: planning it cost a whole call and added nothing. On only
; when (config fast-plan on) — the CLI sets it; tests script their plans.
(= (fast-plan-for $goal)
   (let $top (top-skills $goal)
        (if (== $top ())
            (plan (task t1 $goal))
            (let $s (car-atom $top) (plan (task t1 $goal (uses $s)))))))

(= (make-plan)
   (if (and (== (collapse (config-value fast-plan)) (on))
            (py-call (text.is_simple_goal (goal-text))))
       (let $p (fast-plan-for (goal-text)) (planned (load-plan $p)))
       (llm-plan)))

; An invalid plan (a cycle, a self-dependency, a bad shape) goes BACK to the model
; once, with the reason, to be corrected — instead of working without a plan.
(= (llm-plan) (llm-plan-with (plan-request) 1))

(= (llm-plan-with $request $attempt)
   (let $r (ask-llm (py-call (prompts.plan_system)) $request)
        (case $r
              (((ok $text)
                  (let $p (check-plan (parse-reply $text))
                       (if (== (car-atom $p) invalid)
                           (if (< $attempt 2)
                               (llm-plan-with (py-call (prompts.plan_retry $request $text (repr $p))) (+ $attempt 1))
                               $p)
                           (planned (load-plan $p)))))
               ($err $err)))))

(= (propose-next)
   (let* (($req (act-request))
          ($r (ask-llm (py-call (prompts.act_system)) $req)))
         (case $r
               (((ok $text) (let $p (check-proposal (parse-reply $text))
                                 (if (unusable-reply $p) (repair-reply $req) $p)))
                ($err $err)))))

; A reply with no usable expression (markdown prose, a final with an unescaped
; quote, an empty reply) is asked for AGAIN at once, showing the model what it
; sent and the format. Before, it only saw "(invalid no-expression)" next turn,
; repeated the mistake, and three in a row ended the run.
; (config repair-replies on): the CLI sets it. Off in tests, where an extra call
; would consume the next scripted reply.
(= (unusable-reply $p)
   (and (== (collapse (config-value repair-replies)) (on))
        (or (== $p (invalid no-expression))
            (or (== $p (invalid unparseable)) (== $p (invalid bad-shape))))))

; An EMPTY reply from a thinking model usually has the step in its hidden
; reasoning ("Use calc tool."): the retry shows that reasoning and the exact
; call of each tool it names (prompts.empty_reply_help).
(= (repair-reply $req)
   (let* (($shown (py-call (reply_parser.last_reply)))
          ($why (py-call (llm_client.last_reasoning)))
          ($cut (py-call (llm_client.last_cut)))       ; cut off at the token limit: "shorter"
          ($s (emit (reply-repair $shown)))
          ($r (ask-llm (py-call (prompts.act_system))
                       (py-call (prompts.act_retry $req $shown $why (prompt-tool-rows) $cut)))))
         (case $r
               (((ok $text)
                   (let $p (check-proposal (parse-reply $text))
                        (if (and (unusable-reply $p) (== (config-value verify-semantic) on))
                            (let $fallback (check-proposal (parse-reply (py-call (reply_parser.prose_final $text))))
                                 (if (== (car-atom $fallback) final) $fallback $p))
                            $p)))
                ($err $err)))))

