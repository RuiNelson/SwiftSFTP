# 003 — `close()` vaza recursos em falhas parciais

**Severidade:** Crítico  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/SFTPClient.swift:169-193`

## Descrição

`close()` executa as sub-operações de shutdown em sequência com `try`. Se qualquer operação intermediária lançar, as operações posteriores são ignoradas: o socket fica aberto, a sessão libssh2 não é liberada e `_closed` permanece `false`, deixando o objeto em estado inconsistente e permitindo tentativas repetidas de fechar.

## Código Problemático

```swift
public func close() async throws {
    try internalStateQueue.sync {
        if let sftpSession = _sftp {
            try SFTPShutdown(sftp: sftpSession)  // se lançar → socket nunca fechado
            _sftp = nil
        }
        try SessionDisconnect(...)               // se lançar → SessionFree e socket ignorados
        try SessionFree(session: session)
        if let socket = _socket {
            try CloseSocket(socket)
            _socket = nil
        }
        _closed = true
    }
}
```

## Comportamento Esperado

Todas as operações de cleanup devem ser tentadas independentemente. Erros individuais podem ser agregados e o primeiro (ou mais relevante) pode ser relançado ao final. `_closed` deve ser definido como `true` antes de qualquer cleanup, para impedir novas chamadas enquanto o shutdown está em andamento.

## Correção Sugerida

Usar `defer` para garantir execução das etapas e coletar o primeiro erro:

```swift
public func close() async throws {
    try internalStateQueue.sync {
        guard !_closed else {
            logger?.warning("Trying to close SFTPClient that was already closed")
            return
        }
        _closed = true

        var firstError: Error?

        if let sftpSession = _sftp {
            do { try SFTPShutdown(sftp: sftpSession) }
            catch { firstError = firstError ?? error }
            _sftp = nil
        }

        do { try SessionDisconnect(session: session, description: "Session disconnected on behalf of the user") }
        catch { firstError = firstError ?? error }

        do { try SessionFree(session: session) }
        catch { firstError = firstError ?? error }

        if let socket = _socket {
            do { try CloseSocket(socket) }
            catch { firstError = firstError ?? error }
            _socket = nil
        }

        logger?.trace("SFTPClient closed successfully")

        if let firstError { throw firstError }
    }
}
```
