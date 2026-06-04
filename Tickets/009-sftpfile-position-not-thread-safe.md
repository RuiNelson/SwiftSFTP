# 009 — `SFTPFile.position` não é protegida pela fila interna

**Severidade:** Média  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/SFTPFile.swift:47-53`

## Descrição

A propriedade `position` acessa diretamente o handle do libssh2 (`SFTPTell` e `SFTPSeek`) sem passar pela `internalStateQueue`, enquanto `handle` é declarado como `nonisolated(unsafe)`. Isso contrasta com `closed`, que é sempre lido e escrito sob proteção da fila.

## Código Problemático

```swift
public var position: UInt64 {
    get { SFTPTell(handle: handle) }     // sem fila
    set { SFTPSeek(handle: handle, offset: newValue) }  // sem fila
}
```

## Impacto

- Acesso concorrente a `position` a partir de diferentes contextos async pode corromper o offset interno do libssh2.
- `truncate(toSize:)` e `set(fileSize:...)` ajustam `position` e depois chamam `set(_:)` — qualquer corrida entre essas duas operações pode corromper o estado do handle.
- O libssh2 não é thread-safe; acessos simultâneos ao mesmo handle sem sincronização são comportamento indefinido.

## Correção Sugerida

Envolver os acessos na fila (e tornar `position` uma propriedade não-computada, separada do handle):

```swift
public var position: UInt64 {
    get { internalStateQueue.sync { SFTPTell(handle: handle) } }
    set { internalStateQueue.sync { SFTPSeek(handle: handle, offset: newValue) } }
}
```

Ou, considerando que o padrão de uso é single-threaded via `async/await`, documentar explicitamente que `SFTPFile` não é safe para uso concorrente a partir de múltiplas tasks.
