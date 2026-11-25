; Tests: tool registry, validation, limits, timeouts, permission gate, audit.
; stdin (piped by run_tests.sh): "y" approves the one approval request below.

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)   ; no waiting in tests

; ---------------- registry ----------------
!(test (declare-tool upper "uppercase text" safe fake_tools.upper) (declared upper))
!(test (declare-tool upper "again" safe fake_tools.upper) (error (duplicate-tool upper)))
!(test (declare-tool x "bad level" super-safe fake_tools.upper) (error (invalid-level x super-safe)))
!(test (tool-known x) False)
!(test (set-tool-option nope timeout 3) (error (unknown-tool nope)))

!(declare-tool digits "only digits" safe fake_tools.upper)
!(set-tool-option digits pattern "[0-9]+")
!(set-tool-option digits max-length 5)
!(declare-tool sleepy "hangs" safe fake_tools.sleepy)
!(set-tool-option sleepy timeout 1)
!(declare-tool chatty "huge output" safe fake_tools.chatty)
!(set-tool-option chatty max-output 20)
!(declare-tool once "one call per run" safe fake_tools.upper)
!(set-tool-option once max-calls 1)
!(declare-tool write-note "save a note" needs-approval fake_tools.write_note)
!(declare-tool buggy "raises" safe fake_tools.crash)

; options: one value per key, defaults when unset
!(set-tool-option digits max-length 6)
!(test (tool-option digits max-length) 6)
!(test (size-atom (collapse (match &caps (tool-setting digits max-length $v) $v))) 1)
!(test (tool-option upper timeout) 30)

; ---------------- gate 2: input validation ----------------
!(test (input-problems digits "123") ())
!(test (input-problems digits "12a") ((bad-format "[0-9]+")))
!(test (input-problems digits "1234567") ((too-long 6)))
!(test (input-problems digits "   ") (empty-input (bad-format "[0-9]+")))
!(test (input-problems upper 42) ())                  ; numbers are checked as text
!(test (execute digits "12a") (error (invalid-input ((bad-format "[0-9]+")))))
!(test (repr (execute digits "42")) "(ok 42)")   ; text "42" from Python, not the number

; ---------------- gate 1: unknown tool ----------------
!(test (car-atom (index-atom (execute rm-rf "/") 1)) unknown-tool)

; ---------------- gate 3: call limit (counts steps in &wm) ----------------
!(test (execute once "a") (ok A))
!(record-step once "a" (ok A))
!(test (execute once "b") (error call-limit))
!(clear-wm)

; ---------------- gate 4: approval ("y" on stdin) ----------------
!(test (execute write-note "hi") (ok saved))
!(test (match &wm (approval write-note "hi" $y) $y) true)
; invalid input is rejected BEFORE you are asked (no approval prompt here)
!(set-tool-option write-note max-length 3)
!(test (execute write-note "too long") (error (invalid-input ((too-long 3)))))
!(test (size-atom (collapse (match &wm (approval $t $i $y) $y))) 1)

; ---------------- gate 5: running ----------------
!(set-config max-retries 0)     ; timeouts are retried; not needed here
!(test (repr (execute sleepy "x")) "(error timeout after 1s)")
!(set-config max-retries 3)
!(test (let (ok $v) (execute chatty "x") (py-call (.endswith $v "[truncated, 10000 chars]"))) True)
!(test (let (ok $v) (execute chatty "x") (py-call (.startswith $v "xxxxxxxxxxxxxxxxxxxx..."))) True)
!(test (car-atom (execute buggy "x")) error)

; ---------------- audit log ----------------
!(test (py-call (fake_tools.audit_has "denied" "rm-rf")) True)
!(test (py-call (fake_tools.audit_has "approval" "write-note")) True)
!(test (py-call (fake_tools.audit_has "run" "sleepy")) True)
