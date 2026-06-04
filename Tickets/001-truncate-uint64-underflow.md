# 001 — UInt64 underflow em `truncate(toSize: 0)`

**Severidade:** Crítico  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/Convenience/File.swift:38-40`

## Descrição

Quando `newSize == 0` é passado para `truncate(toSize:)`, a expressão `newSize - 1` sofre underflow de `UInt64`, resultando em `position = UInt64.max`. O seek vai para um offset astronômico antes da chamada ao `fsetstat`, corrompendo o estado do handle.

## Código Problemático

```swift
func truncate(toSize newSize: UInt64) async throws {
    if position >= newSize {
        position = newSize - 1  // underflow quando newSize == 0
    }
    ...
}
```

## Comportamento Esperado

Truncar para zero bytes é uma operação legítima. Quando `newSize == 0`, o `position` deve ser definido como `0` (não é possível estar antes do início), e a operação de `fsetstat` deve prosseguir normalmente.

## Correção Sugerida

```swift
func truncate(toSize newSize: UInt64) async throws {
    if newSize == 0 {
        position = 0
    } else if position >= newSize {
        position = newSize - 1
    }

    var new = FileAttributes()
    new.flags = [.size]
    new.fileSize = newSize
    try await set(new)
}
```
