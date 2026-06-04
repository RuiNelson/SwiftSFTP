# 005 — `login()` não tem proteção contra chamadas concorrentes

**Severidade:** Alta  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/SFTPClient.swift:142-167`

## Descrição

`login()` é um método `async throws` sem nenhum guard de reentrância. Duas chamadas concorrentes passam pelo `checkClosed()` simultaneamente e ambas avançam para `SessionHandshakeTCP`, `authenticate()` e `SFTPInit`. A segunda chamada sobrescreve `_socket` e `_sftp` — o socket e a sessão SFTP da primeira invocação são vazados sem fechar.

## Código Problemático

```swift
public func login(timeOut: TimeInterval = 10.0) async throws {
    try checkClosed()          // não detecta "já logado" nem "login em progresso"

    let socket = try SessionHandshakeTCP(...)
    internalStateQueue.sync { self._socket = socket }  // sobrescreve o anterior

    try authenticate()

    let sftp = try SFTPInit(session: session)
    internalStateQueue.sync { self._sftp = sftp }      // sobrescreve o anterior
}
```

## Comportamento Esperado

Chamar `login()` quando já logado deve ser no-op ou lançar um erro específico (ex.: `AlreadyLoggedIn`). Não deve vazar recursos.

## Correção Sugerida

Adicionar uma verificação no início de `login()` protegida pela fila:

```swift
public func login(timeOut: TimeInterval = 10.0) async throws {
    try checkClosed()

    let alreadyLoggedIn = internalStateQueue.sync { _sftp != nil }
    guard !alreadyLoggedIn else { return }

    ...
}
```

Isso não elimina a corrida entre verificação e execução em cenário estritamente concorrente, mas resolve o caso prático. Uma solução mais robusta exigiria um estado de "login em andamento" ou um ator (`actor`) para serializar o acesso.
