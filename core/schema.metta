; schema.metta — the shape of P-agent's knowledge, and the rules over it.
;
;   &caps  capabilities you write   (tool ...) (skill ...) (skill-needs ...)
;   &kb    long-term facts          (fact CONTENT (meta SOURCE TIME CONF))   saved
;   &wm    working memory           (goal ...) (task ...) (depends ...) (step ...)
;
; Remember: add-atom does not evaluate its argument, so every computed value
; (time, looked-up atoms) is bound with let/let* before add-atom.

; ===================================================================
; &caps — config (one value per key)
; ===================================================================
;   (config KEY VALUE)    e.g. (config max-iterations 12) (config brain gemini)

(= (config-value $k) (match &caps (config $k $v) $v))

(= (set-config $k $v)
   (let $removed (collapse (let $old (match &caps (config $k $x) (config $k $x))
                                (remove-atom &caps $old)))
        (add-atom &caps (config $k $v))))

; ===================================================================
; &caps — tools and skills (declared by the developer at startup)
; ===================================================================
;   (tool-impl NAME module.function)    Python function that runs the tool
;   (tool NAME "description" LEVEL)     LEVEL = safe | needs-approval
;   (skill NAME "description")
;   (skill-needs SKILL TOOL)

(permission-level safe)
(permission-level needs-approval)

(= (tool-level $t) (match &caps (tool $t $d $l) $l))

; Deny by default: unknown tools are never allowed.
(= (allowed $t)
   (== (collapse (match &caps (tool $t $d safe) yes)) (yes)))

(= (needs-approval $t)
   (== (collapse (match &caps (tool $t $d needs-approval) yes)) (yes)))

; Tools a skill needs that are NOT declared.
(= (missing-tools $s)
   (collapse (let $t (match &caps (skill-needs $s $x) $x)
                  (if (== (collapse (tool-level $t)) ()) $t (empty)))))

(= (skill-available $s) (== (missing-tools $s) ()))

; What gets shown to Gemini later: ((name "desc" level) ...)
(= (tool-catalog) (collapse (match &caps (tool $n $d $l) ($n $d $l))))
(= (skill-catalog)
   (collapse (let $s (match &caps (skill $n $d) ($n $d))
                  (if (skill-available (car-atom $s)) $s (empty)))))

; ===================================================================
; &kb — long-term facts with metadata
; ===================================================================
;   (fact CONTENT (meta SOURCE TIME CONFIDENCE))
; CONTENT is any expression, e.g. (capital france paris).
; One fact per CONTENT: remembering it again replaces the old metadata.

(= (forget $c)
   (let $old (match &kb (fact $c $m) (fact $c $m))
        (remove-atom &kb $old)))

(= (remember $c $src $conf)
   (let* (($removed (collapse (forget $c)))
          ($t (current-time)))
         (add-atom &kb (fact $c (meta $src $t $conf)))))

; Facts matching a pattern, with confidence: (((capital france paris) 0.9) ...)
(= (recall $pattern)
   (collapse (match &kb (fact $pattern (meta $s $t $c)) ($pattern $c))))

(= (fact-count) (size-atom (collapse (get-atoms &kb))))

; ===================================================================
; &wm — goal, tasks, steps
; ===================================================================
;   (goal "text")
;   (task ID "description" STATUS)
;   (depends ID OTHER-ID)                  ID needs OTHER-ID completed first
;   (step N TOOL INPUT OUTCOME)            OUTCOME = (ok X) | (error X)

(task-status pending)
(task-status ready)
(task-status running)
(task-status completed)
(task-status blocked)
(task-status failed)
(task-status cancelled)

(= (valid-status $s) (== (collapse (match &self (task-status $s) yes)) (yes)))

(= (set-goal $text)
   (let $removed (collapse (let $g (match &wm (goal $x) (goal $x)) (remove-atom &wm $g)))
        (add-atom &wm (goal $text))))

(= (add-task $id $desc) (add-atom &wm (task $id $desc pending)))
(= (add-dependency $id $on) (add-atom &wm (depends $id $on)))

(= (status-of $id) (match &wm (task $id $d $s) $s))

; Change a task's status; refuses statuses not in the list above.
(= (set-status $id $new)
   (if (valid-status $new)
       (let ($d $old) (match &wm (task $id $d $s) ($d $s))
            (let $r (remove-atom &wm (task $id $d $old))
                 (add-atom &wm (task $id $d $new))))
       (error invalid-status $new)))

; Dependencies of $id that are not completed yet.
(= (open-deps $id)
   (collapse (let $d (match &wm (depends $id $x) $x)
                  (if (== (status-of $d) completed) (empty) $d))))

; A pending task is ready when all its dependencies are completed.
(= (is-ready $id)
   (and (== (status-of $id) pending) (== (open-deps $id) ())))

; A pending task is blocked when a dependency failed, was cancelled, or is blocked.
(= (is-blocked $id)
   (not (== (collapse (let $d (match &wm (depends $id $x) $x)
                           (let $s (status-of $d)
                                (if (or (== $s blocked) (or (== $s failed) (== $s cancelled))) $d (empty)))))
            ())))

(= (ready-tasks)
   (collapse (let $id (match &wm (task $x $d pending) $x)
                  (if (is-ready $id) $id (empty)))))

(= (all-done)
   (== (collapse (let $s (match &wm (task $x $d $st) $st)
                      (if (or (== $s completed) (== $s cancelled)) (empty) $s)))
       ()))

; Steps (the tool history)
(= (step-count) (size-atom (collapse (match &wm (step $n $t $i $o) $n))))

(= (record-step $tool $input $outcome)
   (let $n (+ 1 (step-count))
        (add-atom &wm (step $n $tool $input $outcome))))

; ---------------- turn counter (context.metta shows it: the model paces long tasks) ----------------
(= (set-turn $i)
   (let $old (collapse (let $a (match &wm (turn $x) (turn $x)) (remove-atom &wm $a)))
        (add-atom &wm (turn $i))))
(= (current-turn)
   (let $t (collapse (match &wm (turn $x) $x)) (if (== $t ()) 0 (car-atom $t))))

; Loop guard: the exact same call already failed twice or more.
(= (stuck $tool $input)
   (>= (size-atom (collapse (match &wm (step $n $tool $input (error $e)) $n))) 2))

; ---------------- task selection (Phase 6) ----------------
; Sequential for now: one current task. (ready-tasks) already returns every
; task that could run, so parallel execution can be added on top later.

(= (next-task)
   (let $r (sort-atom (ready-tasks))
        (if (== $r ()) none (car-atom $r))))

(= (running-tasks) (collapse (match &wm (task $id $d running) $id)))

; the task being worked on: a running one, else the next ready one, else none
(= (current-task)
   (let $run (running-tasks)
        (if (== $run ()) (next-task) (car-atom $run))))

; acting on the current task marks it running (pending/ready → running)
(= (start-current-task)
   (let $t (current-task)
        (if (== $t none)
            none
            (if (== (status-of $t) running) $t (let $r (set-status $t running) $t)))))

; mark pending tasks whose dependencies failed as blocked, repeating until
; nothing changes (so blocking spreads down chains t1 → t2 → t3)
(= (block-once)
   (collapse (let $id (match &wm (task $x $d pending) $x)
                  (if (is-blocked $id) (let $r (set-status $id blocked) $id) (empty)))))

(= (refresh-blocked)
   (let $new (block-once)
        (if (== $new ()) () (union-atom $new (refresh-blocked)))))

(= (fail-task $id)
   (let $r (set-status $id failed) (refresh-blocked)))

; ---------------- shared basics (used by llm, memory, tools) ----------------
; Defined here, the base layer, so no module depends on a later one
; (PeTTa compiles in load order: a rule used before it is defined is just a symbol).
(= (tool-known $t) (not (== (collapse (tool-level $t)) ())))
(= (goal-text) (match &wm (goal $g) $g))

; tasks not completed or cancelled (moved here from agent.metta: verify.metta uses it)
(= (open-tasks)
   (collapse (match &wm (task $id $d $s)
                    (if (or (== $s completed) (== $s cancelled)) (empty) $id))))

; ---------------- output: the core never prints directly ----------------
; (emit EVENT) → (config ui pretty): core/ui.py renders it (the CLI)
;              → otherwise: printed as a plain atom (tests, logs)
; A different interface (e.g. web) only needs a different renderer.
!(import! &self "ui.py")

(= (emit $x)
   (if (== (collapse (config-value ui)) (pretty))
       (py-call (ui.render $x))
       (println! $x)))
