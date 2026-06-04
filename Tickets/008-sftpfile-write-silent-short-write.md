# 008 — `SFTPFile.write()` retorna silenciosamente uma contagem menor sem erro

**Severidade:** Média  
**Status:** Resolvido  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/SFTPFile.swift:83-101`

## Descrição

O loop de escrita em `SFTPFile.write(_:)` interrompe silenciosamente quando `SFTPWrite` retorna `0`, retornando um total de bytes escrito potencialmente menor que `data.count`. Nenhum erro é lançado. Como o método é anotado com `@discardableResult`, chamadores que não inspecionam o retorno podem não perceber que apenas parte dos dados foi gravada.

## Código Problemático

```swift
@discardableResult public func write(_ data: Data) async throws -> Int {
    ...
    while bytesWritten < data.count {
        let written = try SFTPWrite(handle: handle, data: chunk)
        guard written > 0 else {
            break          // ← sai sem erro, bytesWritten < data.count
        }
        bytesWritten += written
    }
    return bytesWritten    // ← pode ser menor que data.count
}
```

## Impacto

- Dados parcialmente escritos passam silenciosamente sem diagnóstico.
- Camadas de conveniência (`FileUploadDownload.swift`) verificam o short-write, mas uso direto via `SFTPFileProtocol` não tem essa proteção garantida.

## Correção Sugerida

Lançar `FileTransferErrors.shortWrite` quando o loop termina antes de escrever todos os bytes:

```swift
guard bytesWritten == data.count else {
    throw FileTransferErrors.shortWrite(expected: data.count, actual: bytesWritten)
}
return bytesWritten
```

Ou documentar explicitamente no protocolo que o retorno pode ser menor e que o chamador é responsável por verificar.
