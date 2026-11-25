; tools.metta — tool registry, input validation, limits, permission gate.
; Needs core/schema.metta. Python side: core/toolrunner.py.
;
;   !(declare-tool NAME "description" safe|needs-approval module.function)
;   !(set-tool-option NAME KEY VALUE)
;       timeout     seconds before the call is abandoned        (default 30)
;       max-length  max characters of input                     (default 2000)
;       max-output  max characters of output kept               (default 4000)
;       max-calls   calls allowed per run-agent                 (default 40)
;       pattern     regex the WHOLE input must match            (repeatable)
;       retry       yes | no: retry temporary errors (timeouts)  (default yes)
;                   use no for tools with side effects (shell) or a person (ask-user)
;       auto-approve  module.function(input) → True when THIS input is harmless, so a
;                   needs-approval tool runs without asking (e.g. a read-only shell
;                   command). False, an error or a crash → you are asked as usual.
;       remember-approval  yes | no: once you approve an exact (tool, input), the same
;                   call runs without asking again for the rest of the session —
;                   helpers included (their working memory starts empty). The prompt
;                   also offers "a": allow this tool for the rest of the session.
;                   Only for calls that are safe to repeat (http-get); default no.
;
;   (execute TOOL INPUT) → (ok X) | (error REASON)   — the only way tools run

!(import! &self "toolrunner.py")
!(import! &self recovery)     ; error-class, retryable, backoff

(default-tool-option timeout 30)
(default-tool-option max-length 2000)
(default-tool-option max-output 4000)
(default-tool-option max-calls 40)     ; runaway guard; long tasks (40 turns) must fit
(default-tool-option allow-empty no)     ; yes for tools that need no input (list-files, now)
(default-tool-option retry yes)
(default-tool-option auto-approve none)
(default-tool-option remember-approval no)

; ---------------- registry ----------------
(= (declare-tool $name $desc $level $impl)
   (if (not (== (collapse (match &self (permission-level $level) yes)) (yes)))
       (error (invalid-level $name $level))
       (if (tool-known $name)
           (error (duplicate-tool $name))
           (let* (($a (add-atom &caps (tool $name $desc $level)))
                  ($b (add-atom &caps (tool-impl $name $impl))))
                 (declared $name)))))

; one value per (tool, key) — except pattern, which may repeat
(= (set-tool-option $t $k $v)
   (if (not (tool-known $t))
       (error (unknown-tool $t))
       (let $removed (if (== $k pattern)
                         ()
                         (collapse (let $o (match &caps (tool-setting $t $k $x) (tool-setting $t $k $x))
                                        (remove-atom &caps $o))))
            ; stored as tool-setting: tool-option is a function (gotcha 8)
            (let $r (add-atom &caps (tool-setting $t $k $v)) (option-set $t $k $v)))))

(= (tool-option $t $k)
   (let $vals (collapse (match &caps (tool-setting $t $k $x) $x))
        (if (== $vals ())
            (match &self (default-tool-option $k $d) $d)
            (car-atom $vals))))

(= (tool-impl-of $t) (match &caps (tool-impl $t $f) $f))
(= (tool-names) (collapse (match &caps (tool $n $d $l) $n)))

; ---------------- input validation (gate 2) ----------------
; → () when fine, else a list of problems, e.g. ((too-long 2000) (bad-format "[0-9]+"))
(= (input-problems $t $input)
   (collapse
     (superpose
       ((if (and (py-call (toolrunner.is_blank $input)) (== (tool-option $t allow-empty) no))
            empty-input (empty))
        (let $max (tool-option $t max-length)
             (if (> (py-call (toolrunner.length $input)) $max) (too-long $max) (empty)))
        (let $p (match &caps (tool-setting $t pattern $x) $x)
             (if (py-call (toolrunner.matches $p $input)) (empty) (bad-format $p)))))))

; ---------------- call limit (gate 3) ----------------
(= (calls-so-far $t) (size-atom (collapse (match &wm (step $n $t $i $o) $n))))
(= (over-limit $t) (>= (calls-so-far $t) (tool-option $t max-calls)))

; ---------------- the gate ----------------
(= (deny $tool $input $reason)
   (let $l (py-call (toolrunner.audit denied $tool $input error (repr $reason)))
        (error $reason)))

(= (execute $tool $input)
   (if (not (tool-known $tool))
       (deny $tool $input (unknown-tool $tool (available (tool-names))))
       (let $problems (input-problems $tool $input)
            (if (not (== $problems ()))
                (deny $tool $input (invalid-input $problems))
                (if (over-limit $tool)
                    (deny $tool $input call-limit)
                    (if (allowed $tool)
                        (run-retrying $tool $input 1)
                        (if (needs-approval $tool)
                            (if (harmless $tool $input)
                                (auto-approved $tool $input)
                                (if (approved-before $tool $input)
                                    (reused-approval $tool $input)
                                    (ask-approval $tool $input)))
                            (deny $tool $input not-permitted))))))))

; the tool's own check says this input cannot do damage (e.g. `ls`, a new file)
(= (harmless $tool $input)
   (let $f (tool-option $tool auto-approve)
        (if (== $f none) False (py-call (toolrunner.check $f $input)))))

(= (auto-approved $tool $input)
   (let* (($r (add-atom &wm (approval $tool $input auto)))
          ($l (py-call (toolrunner.audit approval $tool $input auto ""))))
         (run-retrying $tool $input 1)))

(= (ask-approval $tool $input)
   (let* (($q (py-call (ui.approval_question $tool $input)))
          ($yes (if (== (tool-option $tool remember-approval) yes)
                    (py-call (io_helper.confirm_remembered $q $tool $input))   ; y / N / a(ll)
                    (py-call (io_helper.confirm $q))))
          ($r (add-atom &wm (approval $tool $input $yes)))
          ($l (py-call (toolrunner.audit approval $tool $input $yes ""))))
         (if $yes (run-retrying $tool $input 1) (error denied-by-user))))

; you already said yes to exactly this call in this session (remember-approval yes)
(= (approved-before $tool $input)
   (if (== (tool-option $tool remember-approval) yes)
       (py-call (io_helper.approved_before $tool $input))
       False))

(= (reused-approval $tool $input)
   (let* (($r (add-atom &wm (approval $tool $input remembered)))
          ($l (py-call (toolrunner.audit approval $tool $input remembered ""))))
         (run-retrying $tool $input 1)))

; ---------------- retry (recovery manager) ----------------
; Temporary errors are retried after a backoff, at most max-retries times.
; Permanent errors (bad input, denied, bugs) are returned at once.
; Retries happen AFTER the gates: you are never asked to approve twice.
(= (note-retry $tool $input $k)
   (let $old (collapse (let $a (match &wm (retried $tool $input $x) (retried $tool $input $x))
                            (remove-atom &wm $a)))
        (add-atom &wm (retried $tool $input $k))))

(= (run-retrying $tool $input $attempt)
   (let $out (run-tool $tool $input)
        (if (and (retryable $out)
                 (and (== (tool-option $tool retry) yes) (<= $attempt (config-value max-retries))))
            (let* (($s (emit (retry $attempt $tool (index-atom $out 1))))
                   ($b (backoff $attempt))
                   ($n (note-retry $tool $input $attempt))
                   ($next (+ $attempt 1)))
                  (run-retrying $tool $input $next))
            $out)))

; ---------------- run (gate 5) ----------------
; Two kinds of implementation:
;   module.function   a Python function, run by toolrunner (thread, timeout, output cap)
;   metta             a MeTTa rule  (= (metta-tool NAME $input) ...)  — runs inside
;                     PeTTa, so it can query the AtomSpaces (e.g. memory tools)
(= (run-tool $tool $input)
   (let $impls (collapse (tool-impl-of $tool))
        (if (== $impls ())
            (deny $tool $input no-implementation)
            (if (== (car-atom $impls) metta)
                (run-metta-tool $tool $input)
                (let $r (py-call (toolrunner.run $tool (car-atom $impls) $input
                                                 (tool-option $tool timeout)
                                                 (tool-option $tool max-output)))
                     (case $r
                           (((ok $x) (ok $x))
                            ((error $x) (error $x)))))))))

; Base rule so PeTTa knows metta-tool is a FUNCTION before capability files add
; their own rules for it (gotcha 12: otherwise later rules would come too late).
(= (metta-tool --no-tool-- $input) (error no-tool))

; a MeTTa tool must return (ok X) or (error X); no result / anything else is an error
(= (run-metta-tool $tool $input)
   (let $rs (collapse (metta-tool $tool $input))
        (if (== $rs ())
            (error (no-metta-implementation $tool))
            (let $r (car-atom $rs)
                 (if (and (is-expression $r) (or (== (car-atom $r) ok) (== (car-atom $r) error)))
                     $r
                     (error (bad-tool-result $r)))))))
