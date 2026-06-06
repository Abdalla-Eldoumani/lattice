# Sudoku solution fixtures

These solutions are verified unique (checked with an independent brute-force solver
during scaffolding). Use them as expected values in correctness and golden tests.
Format: 81 (or 16) characters, row-major, digits only.

## easy.txt (9x9, box 3x3)

```
534678912672195348198342567859761423426853791713924856961537284287419635345286179
```

## hard-17.txt (9x9, box 3x3, 17 given clues, minimal)

```
693784512487512936125963874932651487568247391741398625319475268856129743274836159
```

## diff-4x4.txt (4x4, box 2x2)

```
1234341243212143
```

The 17-clue instance is a genuine minimal Sudoku (17 is the proven minimum number of
clues for a uniquely solvable 9x9). It exists to make the search visibly work. Add more
verified hard instances from the published 17-clue collection (Royle / McGuire et al.)
when building the gallery; verify each new instance has exactly one solution before
committing it.
