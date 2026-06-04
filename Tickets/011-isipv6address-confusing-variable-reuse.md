# 011 — Lógica confusa com reatribuição de variável em `isIPv6Address`

**Severidade:** Baixa  
**Status:** Resolvido (substituído por inet_pton)  
**Arquivo:** `Sources/SwiftSFTP/SFTPClient/StructsAndEnums/TCPLocation.swift:95-108`

## Descrição

A variável `containsDoubleColon` começa como resultado de `.contains("::")` (presença de `::` na string), mas é imediatamente sobrescrita dentro do próprio bloco `if containsDoubleColon` com um resultado de comparação numérica sobre a contagem de colons. A variável passa a representar dois conceitos diferentes ao longo da função, tornando o raciocínio difícil e aumentando o risco de bugs ao modificar a lógica.

## Código Problemático

```swift
var containsDoubleColon = string.contains("::")   // ← "tem ::"
let colonCount = string.count(where: { $0 == ":" })

if containsDoubleColon {
    if string.hasPrefix("::") {
        containsDoubleColon = (colonCount <= 7)   // ← significado mudado: "contagem é válida"
    }
    else if string.hasSuffix("::") {
        containsDoubleColon = (colonCount <= 7)
    }
    else {
        containsDoubleColon = (colonCount <= 6)
    }
}
else {
    containsDoubleColon = (colonCount == 7)       // ← agora representa outra coisa ainda
}
```

## Correção Sugerida

Separar os dois conceitos em variáveis distintas:

```swift
let hasDoubleColon = string.contains("::")
let colonCount = string.count(where: { $0 == ":" })

let colonCountIsValid: Bool
if hasDoubleColon {
    if string.hasPrefix("::") || string.hasSuffix("::") {
        colonCountIsValid = colonCount <= 7
    } else {
        colonCountIsValid = colonCount <= 6
    }
} else {
    colonCountIsValid = colonCount == 7
}

if colonCountIsValid {
    ...
}
```
