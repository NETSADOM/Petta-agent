; Persistence (part 2): runs in a FRESH PeTTa process after test_bridge.metta.
; Nothing is in &kb until we load it from disk.

!(import! &self ../core/store)

!(test (size-atom (collapse (get-atoms &kb))) 0)
!(test (load-space &kb "data/test_kb.metta") 6)

!(test (collapse (match &kb (fact sky-color $v $c) ($v $c))) ((blue 0.95)))
!(test (match &kb (tool write-file $d $p) $p) needs-approval)
!(test (match &kb (action calc $e) (repr $e)) "(+ 2 3)")
!(test (match &kb (note $s) $s) "she said \"hi\"")
; the variable survives as a variable: it still unifies with anything
!(test (match &kb (rule (likes tom) $body) $body) (friend tom))

; missing file -> empty, not a crash
!(test (load-space &kb2 "data/does_not_exist.metta") 0)
