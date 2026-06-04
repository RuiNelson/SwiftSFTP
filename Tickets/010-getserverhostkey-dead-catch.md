# 010 — Dead code: `catch { throw error }` em `getServerHostKey`

**Severidade:** Média  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/SFTPClient.swift:122-124`

## Descrição

O bloco `do/catch` dentro de `getServerHostKey` captura qualquer erro e o relança sem modificação. É funcionalmente idêntico a não ter o bloco `do/catch`. O código não adiciona nenhum comportamento e pode induzir o leitor a pensar que existe algum tratamento especial sendo feito.

## Código Problemático

```swift
do {
    let socket = try SessionHandshakeTCP(...)
    defer { try? CloseSocket(socket) }

    let shortHand = try SessionHostKeyString(session: session)
    ...
    return ...
}
catch {
    throw error    // ← captura e relança sem modificação — dead code
}
```

## Correção Sugerida

Remover o bloco `do/catch` e deixar os erros propagar naturalmente:

```swift
let socket = try SessionHandshakeTCP(
    session: session,
    host: openSocketIn.trimmedHostname,
    port: openSocketIn.port
)
defer { try? CloseSocket(socket) }

let shortHand = try SessionHostKeyString(session: session)

if shortHandForm {
    return shortHand
}
else {
    return "\(openSocketIn.knownHostsHost) \(shortHand)"
}
```
