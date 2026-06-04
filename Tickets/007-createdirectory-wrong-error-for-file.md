# 007 — Erro errado lançado em `createDirectory` quando o caminho é um arquivo regular

**Severidade:** Média  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/SFTPClient.swift:297-299`

## Descrição

Quando `createDirectory(path:makePath:mode:)` detecta que o caminho de destino já existe como arquivo regular, lança `FileTransferErrors.remotePathIsADirectory(path:)`. O nome do erro diz "o caminho remoto é um diretório", mas a situação real é o oposto: o caminho é um arquivo, não um diretório.

## Código Problemático

```swift
if let metadata {
    if metadata.isDirectory {
        return  // já existe como diretório — ok
    }
    else if metadata.isRegularFile {
        throw FileTransferErrors.remotePathIsADirectory(path: path)  // ← caso errado
    }
}
```

## Impacto

Chamadores que inspecionam o tipo de erro para tomar decisões recebem informação incorreta. Mensagens de log e diagnóstico apresentam a causa invertida.

## Correção Sugerida

Adicionar um novo caso a `FileTransferErrors`:

```swift
/// O caminho remoto de destino já existe como arquivo regular.
case remotePathIsAFile(path: String)
```

E substituir o throw:

```swift
else if metadata.isRegularFile {
    throw FileTransferErrors.remotePathIsAFile(path: path)
}
```
