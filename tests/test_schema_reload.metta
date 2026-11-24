; Fresh process: facts and their metadata survive a restart, and
; remember still deduplicates against reloaded facts.

!(import! &self ../core/store)
!(import! &self ../core/schema)

!(test (load-space &kb "data/test_schema_kb.metta") 1)
!(test (recall (capital france $x)) (((capital france paris) 0.95)))
!(test (match &kb (fact (capital france paris) (meta $s $t $c)) $s) web)
!(test (> (match &kb (fact (capital france paris) (meta $s $t $c)) $t) 0) True)

!(remember (capital france paris) user 0.99)
!(test (fact-count) 1)
!(test (recall (capital france $x)) (((capital france paris) 0.99)))
