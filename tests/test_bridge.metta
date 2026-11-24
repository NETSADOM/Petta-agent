; Phase 1 bridge tests: everything P-agent will rely on, in one process.
; Ends by saving &kb so test_persist.metta can reload it in a fresh process.

!(import! &self ../core/store)

; --- 1. Create / query atoms in a named space ---
!(add-atom &kb (tool calc "evaluate arithmetic" safe))
!(add-atom &kb (tool write-file "write a file" needs-approval))
!(test (collapse (match &kb (tool $n $d safe) $n)) (calc))

; --- 2. Update = remove + add ---
!(add-atom &kb (fact sky-color blue 0.9))
!(remove-atom &kb (fact sky-color blue 0.9))
!(add-atom &kb (fact sky-color blue 0.95))
!(test (collapse (match &kb (fact sky-color $v $c) ($v $c))) ((blue 0.95)))

; --- 3. Symbolic reasoning: a permission rule over the knowledge base ---
; Deny by default: collapse turns "no match" into (), so unknown tools give False.
; (A plain `case` over `match` returns NOTHING for unknown tools — unsafe.)
(= (allowed $t)
   (== (collapse (match &kb (tool $t $_ safe) yes)) (yes)))
!(test (allowed calc) True)
!(test (allowed write-file) False)
!(test (allowed unknown-tool) False)

; --- 4. Add a rule at runtime (how skills can be loaded later) ---
!(add-atom &self (= (double $x) (* 2 $x)))
!(test (double 21) 42)

; --- 5. Parse LLM text into atoms (sread), stored unevaluated ---
!(let $a (sread "(action calc (+ 2 3))") (add-atom &kb $a))
!(test (match &kb (action calc $e) (repr $e)) "(+ 2 3)")

; --- 6. Python interop + error catching ---
!(test (py-call (.upper "petta")) PETTA)
(= (safe-int $s)
   (case (catch (py-call (builtins.int $s)))
         (((Error $a $b) failed) ($v (ok $v)))))
!(test (safe-int "42") (ok 42))
!(test (safe-int "abc") failed)

; --- 7. Persistence (part 1): save, including a variable and a quoted string ---
!(add-atom &kb (rule (likes $x) (friend $x)))
!(add-atom &kb (note "she said \"hi\""))
!(test (save-space &kb "data/test_kb.metta") 6)
