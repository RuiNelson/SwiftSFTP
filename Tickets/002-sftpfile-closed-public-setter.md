# 002 — `SFTPFile.closed` tem setter público

**Severidade:** Crítico  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/SFTPFile.swift:12-23`

## Descrição

`SFTPFile.closed` expõe um setter público, permitindo que qualquer código externo marque o handle como fechado sem realmente chamar `SFTPCloseHandle`. Isso vaza o handle do libssh2 silenciosamente e viola o invariante de fechamento da classe.

## Código Problemático

```swift
public var closed: Bool {
    get { ... }
    set {                          // ← setter público não deveria existir
        internalStateQueue.sync {
            _closed = newValue
        }
    }
}
```

## Impacto

- Handle do libssh2 vazado sem erro ou aviso.
- O invariante de `trapOnDeInitWithoutClose` é contornável externamente.
- `SFTPClientProtocol` declara `closed` apenas com `{ get }`, portanto a assimetria é inesperada.

## Correção Sugerida

Alterar a visibilidade do setter:

```swift
public private(set) var closed: Bool {
    ...
}
```

Ou manter a propriedade computada sem setter público, da mesma forma que `SFTPClient.closed` é implementado.
