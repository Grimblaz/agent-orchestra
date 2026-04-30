#Requires -Version 7.0
<#
.SYNOPSIS
    Library for frame predicate parsing. Dot-source and call ConvertTo-FVPredicate.
#>

function New-FVParseError {
    param(
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$Message
    )

    return [PSCustomObject]@{
        Kind     = 'ParseError'
        Position = $Position
        Message  = $Message
    }
}

function Test-FVParseError {
    param($Value)

    return (
        $null -ne $Value -and
        $null -ne $Value.PSObject.Properties['Kind'] -and
        $Value.Kind -eq 'ParseError'
    )
}

function New-FVToken {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [AllowNull()]$Value,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][int]$Length
    )

    return [PSCustomObject]@{
        Kind     = $Kind
        Value    = $Value
        Position = $Position
        Length   = $Length
    }
}

function New-FVTokenStream {
    param([object[]]$Tokens)

    return [PSCustomObject]@{
        Kind   = 'TokenStream'
        Tokens = [object[]]$Tokens
    }
}

function Test-FVIdentifierStart {
    param([char]$Character)

    $code = [int][char]$Character
    return (
        ($code -ge [int][char]'A' -and $code -le [int][char]'Z') -or
        ($code -ge [int][char]'a' -and $code -le [int][char]'z') -or
        $Character -eq [char]'_'
    )
}

function Test-FVIdentifierPart {
    param([char]$Character)

    $code = [int][char]$Character
    return (
        (Test-FVIdentifierStart -Character $Character) -or
        ($code -ge [int][char]'0' -and $code -le [int][char]'9')
    )
}

function Get-FVSingleCharacterTokenKind {
    param([char]$Character)

    switch ([string]$Character) {
        '(' { return 'LParen' }
        ')' { return 'RParen' }
        '[' { return 'LBracket' }
        ']' { return 'RBracket' }
        ',' { return 'Comma' }
        default { return $null }
    }
}

function New-FVTokenReadResult {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][int]$NextIndex
    )

    return [PSCustomObject]@{
        Value     = $Value
        NextIndex = $NextIndex
    }
}

function Read-FVQuotedStringToken {
    param(
        [Parameter(Mandatory)][string]$Predicate,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $quote = $Predicate[$StartIndex]
    $index = $StartIndex + 1
    $builder = [System.Text.StringBuilder]::new()
    $closed = $false

    while ($index -lt $Predicate.Length) {
        $current = $Predicate[$index]
        if ($current -eq [char]92) {
            if ($index + 1 -ge $Predicate.Length) {
                return (New-FVTokenReadResult -Value (New-FVParseError -Position $StartIndex -Message 'Unterminated string literal.') -NextIndex $index)
            }

            [void]$builder.Append($Predicate[$index + 1])
            $index += 2
            continue
        }

        if ($current -eq $quote) {
            $index++
            $closed = $true
            break
        }

        [void]$builder.Append($current)
        $index++
    }

    if (-not $closed) {
        return (New-FVTokenReadResult -Value (New-FVParseError -Position $StartIndex -Message 'Unterminated string literal.') -NextIndex $index)
    }

    $token = New-FVToken -Kind 'String' -Value $builder.ToString() -Position $StartIndex -Length ($index - $StartIndex)
    return (New-FVTokenReadResult -Value $token -NextIndex $index)
}

function Read-FVNumberToken {
    param(
        [Parameter(Mandatory)][string]$Predicate,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $index = $StartIndex
    if ($Predicate[$index] -eq [char]'-') {
        $index++
    }

    while ($index -lt $Predicate.Length -and [char]::IsDigit($Predicate[$index])) {
        $index++
    }

    if ($index -lt $Predicate.Length -and $Predicate[$index] -eq [char]'.' -and $index + 1 -lt $Predicate.Length -and [char]::IsDigit($Predicate[$index + 1])) {
        $index++
        while ($index -lt $Predicate.Length -and [char]::IsDigit($Predicate[$index])) {
            $index++
        }
    }

    if ($index -lt $Predicate.Length -and $Predicate[$index] -in @([char]'e', [char]'E')) {
        $exponentStart = $index
        $index++
        if ($index -lt $Predicate.Length -and $Predicate[$index] -in @([char]'+', [char]'-')) {
            $index++
        }

        if ($index -ge $Predicate.Length -or -not [char]::IsDigit($Predicate[$index])) {
            return (New-FVTokenReadResult -Value (New-FVParseError -Position $exponentStart -Message 'Malformed number literal.') -NextIndex $index)
        }

        while ($index -lt $Predicate.Length -and [char]::IsDigit($Predicate[$index])) {
            $index++
        }
    }

    $number = $Predicate.Substring($StartIndex, $index - $StartIndex)
    $token = New-FVToken -Kind 'Number' -Value $number -Position $StartIndex -Length ($index - $StartIndex)
    return (New-FVTokenReadResult -Value $token -NextIndex $index)
}

function New-FVIdentifierOrKeywordToken {
    param(
        [Parameter(Mandatory)][string]$Identifier,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][int]$Length
    )

    switch ($Identifier.ToUpperInvariant()) {
        'AND' { return (New-FVToken -Kind 'LogicalOperator' -Value 'AND' -Position $Position -Length $Length) }
        'OR' { return (New-FVToken -Kind 'LogicalOperator' -Value 'OR' -Position $Position -Length $Length) }
        'NOT' { return (New-FVToken -Kind 'Not' -Value 'NOT' -Position $Position -Length $Length) }
        'IN' { return (New-FVToken -Kind 'Comparator' -Value 'in' -Position $Position -Length $Length) }
        'TRUE' { return (New-FVToken -Kind 'Boolean' -Value $true -Position $Position -Length $Length) }
        'FALSE' { return (New-FVToken -Kind 'Boolean' -Value $false -Position $Position -Length $Length) }
        default { return (New-FVToken -Kind 'Identifier' -Value $Identifier -Position $Position -Length $Length) }
    }
}

function Read-FVIdentifierOrKeywordToken {
    param(
        [Parameter(Mandatory)][string]$Predicate,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $index = $StartIndex + 1
    while ($index -lt $Predicate.Length) {
        $current = $Predicate[$index]
        if (Test-FVIdentifierPart -Character $current) {
            $index++
            continue
        }

        if ($current -eq [char]'.') {
            $index++
            if ($index -ge $Predicate.Length -or -not (Test-FVIdentifierStart -Character $Predicate[$index])) {
                return (New-FVTokenReadResult -Value (New-FVParseError -Position $index -Message "Expected identifier segment after '.'.") -NextIndex $index)
            }

            $index++
            continue
        }

        break
    }

    $identifier = $Predicate.Substring($StartIndex, $index - $StartIndex)
    $token = New-FVIdentifierOrKeywordToken -Identifier $identifier -Position $StartIndex -Length ($index - $StartIndex)
    return (New-FVTokenReadResult -Value $token -NextIndex $index)
}

function Get-FVTokens {
    [CmdletBinding()]
    param([AllowNull()][string]$Predicate)

    if ($null -eq $Predicate -or [string]::IsNullOrWhiteSpace($Predicate)) {
        return (New-FVParseError -Position 0 -Message 'Predicate is required.')
    }

    $tokens = [System.Collections.Generic.List[object]]::new()
    $length = $Predicate.Length
    $index = 0

    while ($index -lt $length) {
        $character = $Predicate[$index]

        if ([char]::IsWhiteSpace($character)) {
            $index++
            continue
        }

        $singleCharacterTokenKind = Get-FVSingleCharacterTokenKind -Character $character
        if ($singleCharacterTokenKind) {
            $tokens.Add((New-FVToken -Kind $singleCharacterTokenKind -Value ([string]$character) -Position $index -Length 1))
            $index++
            continue
        }

        if ($index + 1 -lt $length) {
            $twoCharacterOperator = $Predicate.Substring($index, 2)
            if ($twoCharacterOperator -in @('==', '!=', '<=', '>=')) {
                $tokens.Add((New-FVToken -Kind 'Comparator' -Value $twoCharacterOperator -Position $index -Length 2))
                $index += 2
                continue
            }
        }

        if ($character -in @([char]'<', [char]'>')) {
            $tokens.Add((New-FVToken -Kind 'Comparator' -Value ([string]$character) -Position $index -Length 1))
            $index++
            continue
        }

        if ($character -eq [char]'=') {
            return (New-FVParseError -Position $index -Message "Unexpected '='. Did you mean '=='?")
        }

        if ($character -eq [char]'!') {
            return (New-FVParseError -Position $index -Message "Unexpected '!'. Did you mean '!='?")
        }

        if ($character -eq [char]34 -or $character -eq [char]39) {
            $readResult = Read-FVQuotedStringToken -Predicate $Predicate -StartIndex $index
            if (Test-FVParseError -Value $readResult.Value) { return $readResult.Value }

            $tokens.Add($readResult.Value)
            $index = $readResult.NextIndex
            continue
        }

        if (($character -eq [char]'-' -and $index + 1 -lt $length -and [char]::IsDigit($Predicate[$index + 1])) -or [char]::IsDigit($character)) {
            $readResult = Read-FVNumberToken -Predicate $Predicate -StartIndex $index
            if (Test-FVParseError -Value $readResult.Value) { return $readResult.Value }

            $tokens.Add($readResult.Value)
            $index = $readResult.NextIndex
            continue
        }

        if (Test-FVIdentifierStart -Character $character) {
            $readResult = Read-FVIdentifierOrKeywordToken -Predicate $Predicate -StartIndex $index
            if (Test-FVParseError -Value $readResult.Value) { return $readResult.Value }

            $tokens.Add($readResult.Value)
            $index = $readResult.NextIndex
            continue
        }

        return (New-FVParseError -Position $index -Message "Unexpected character '$character'.")
    }

    $tokens.Add((New-FVToken -Kind 'EOF' -Value '' -Position $length -Length 0))
    return (New-FVTokenStream -Tokens $tokens.ToArray())
}

function New-FVParserState {
    param([Parameter(Mandatory)][object[]]$Tokens)

    return [PSCustomObject]@{
        Tokens = [object[]]$Tokens
        Index  = 0
    }
}

function Get-FVCurrentToken {
    param([Parameter(Mandatory)]$State)

    if ($State.Index -ge $State.Tokens.Count) {
        return $State.Tokens[$State.Tokens.Count - 1]
    }

    return $State.Tokens[$State.Index]
}

function Move-FVToken {
    param([Parameter(Mandatory)]$State)

    $token = Get-FVCurrentToken -State $State
    if ($State.Index -lt ($State.Tokens.Count - 1)) {
        $State.Index = $State.Index + 1
    }

    return $token
}

function New-FVIdentifierNode {
    param([Parameter(Mandatory)]$Token)

    return [PSCustomObject]@{
        Kind     = 'Identifier'
        Name     = $Token.Value
        Position = $Token.Position
    }
}

function New-FVCallNode {
    param(
        [Parameter(Mandatory)]$NameToken,
        [AllowEmptyCollection()][object[]]$Arguments
    )

    return [PSCustomObject]@{
        Kind      = 'Call'
        Name      = $NameToken.Value
        Arguments = [object[]]$Arguments
        Position  = $NameToken.Position
    }
}

function New-FVScalarLiteralNode {
    param(
        [Parameter(Mandatory)][string]$LiteralType,
        [AllowNull()]$Value,
        [Parameter(Mandatory)][int]$Position
    )

    return [PSCustomObject]@{
        Kind        = 'Literal'
        LiteralType = $LiteralType
        Value       = $Value
        Position    = $Position
    }
}

function New-FVArrayLiteralNode {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][int]$Position
    )

    return [PSCustomObject]@{
        Kind        = 'Literal'
        LiteralType = 'Array'
        Items       = [object[]]$Items
        Position    = $Position
    }
}

function New-FVComparisonNode {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)][string]$Operator,
        [Parameter(Mandatory)]$Right,
        [Parameter(Mandatory)][int]$Position
    )

    return [PSCustomObject]@{
        Kind     = 'Comparison'
        Left     = $Left
        Operator = $Operator
        Right    = $Right
        Position = $Position
    }
}

function New-FVLogicalNode {
    param(
        [Parameter(Mandatory)][string]$Operator,
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right,
        [Parameter(Mandatory)][int]$Position
    )

    return [PSCustomObject]@{
        Kind     = 'Logical'
        Operator = $Operator
        Left     = $Left
        Right    = $Right
        Position = $Position
    }
}

function New-FVNotNode {
    param(
        [Parameter(Mandatory)]$Operand,
        [Parameter(Mandatory)][int]$Position
    )

    return [PSCustomObject]@{
        Kind     = 'Not'
        Operand  = $Operand
        Position = $Position
    }
}

function ConvertTo-FVExpression {
    param([Parameter(Mandatory)]$State)

    return (ConvertTo-FVOrExpression -State $State)
}

function ConvertTo-FVLogicalChainExpression {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Operator,
        [Parameter(Mandatory)][scriptblock]$OperandParser
    )

    $left = & $OperandParser $State
    if (Test-FVParseError -Value $left) { return $left }

    while ($true) {
        $current = Get-FVCurrentToken -State $State
        if ($current.Kind -ne 'LogicalOperator' -or $current.Value -ne $Operator) {
            break
        }

        $operatorToken = Move-FVToken -State $State
        $rightStartIndex = $State.Index
        $right = & $OperandParser $State
        if (Test-FVParseError -Value $right) {
            $current = Get-FVCurrentToken -State $State
            if ($current.Kind -eq 'EOF' -and $State.Index -eq $rightStartIndex) {
                return (New-FVParseError -Position $operatorToken.Position -Message "Trailing operator '$($operatorToken.Value)'.")
            }

            return $right
        }

        $left = New-FVLogicalNode -Operator $operatorToken.Value -Left $left -Right $right -Position $operatorToken.Position
    }

    return $left
}

function ConvertTo-FVOrExpression {
    param([Parameter(Mandatory)]$State)

    return (ConvertTo-FVLogicalChainExpression -State $State -Operator 'OR' -OperandParser {
            param($ParserState)
            ConvertTo-FVAndExpression -State $ParserState
        })
}

function ConvertTo-FVAndExpression {
    param([Parameter(Mandatory)]$State)

    return (ConvertTo-FVLogicalChainExpression -State $State -Operator 'AND' -OperandParser {
            param($ParserState)
            ConvertTo-FVUnaryExpression -State $ParserState
        })
}

function ConvertTo-FVUnaryExpression {
    param([Parameter(Mandatory)]$State)

    $current = Get-FVCurrentToken -State $State
    if ($current.Kind -ne 'Not') {
        return (ConvertTo-FVPrimaryExpression -State $State)
    }

    $notToken = Move-FVToken -State $State
    $next = Get-FVCurrentToken -State $State
    if ($next.Kind -eq 'EOF') {
        return (New-FVParseError -Position $notToken.Position -Message "Missing operand after 'NOT'.")
    }

    if ($next.Kind -eq 'Not') {
        return (New-FVParseError -Position $next.Position -Message "Unexpected 'NOT' after 'NOT'.")
    }

    if ($next.Kind -in @('LogicalOperator', 'Comparator', 'RParen', 'Comma', 'RBracket')) {
        return (New-FVParseError -Position $next.Position -Message "Expected comparison after 'NOT'.")
    }

    $operand = ConvertTo-FVUnaryExpression -State $State
    if (Test-FVParseError -Value $operand) { return $operand }

    return (New-FVNotNode -Operand $operand -Position $notToken.Position)
}

function ConvertTo-FVPrimaryExpression {
    param([Parameter(Mandatory)]$State)

    $current = Get-FVCurrentToken -State $State
    switch ($current.Kind) {
        'EOF' {
            return (New-FVParseError -Position $current.Position -Message 'Expected comparison.')
        }
        'LParen' {
            $openToken = Move-FVToken -State $State
            $expression = ConvertTo-FVExpression -State $State
            if (Test-FVParseError -Value $expression) { return $expression }

            $closeToken = Get-FVCurrentToken -State $State
            if ($closeToken.Kind -eq 'EOF') {
                return (New-FVParseError -Position $openToken.Position -Message "Unclosed '('.")
            }

            if ($closeToken.Kind -ne 'RParen') {
                return (New-FVParseError -Position $closeToken.Position -Message "Expected ')'.")
            }

            $null = Move-FVToken -State $State
            return $expression
        }
        'Identifier' {
            return (ConvertTo-FVIdentifierExpression -State $State)
        }
        'LogicalOperator' {
            return (New-FVParseError -Position $current.Position -Message "Unexpected operator '$($current.Value)'.")
        }
        'Comparator' {
            return (New-FVParseError -Position $current.Position -Message "Unexpected comparator '$($current.Value)'.")
        }
        'RParen' {
            return (New-FVParseError -Position $current.Position -Message "Unexpected ')'.")
        }
        default {
            return (New-FVParseError -Position $current.Position -Message "Expected identifier or '('.")
        }
    }
}

function ConvertTo-FVIdentifierExpression {
    param([Parameter(Mandatory)]$State)

    $identifierToken = Move-FVToken -State $State
    $left = New-FVIdentifierNode -Token $identifierToken
    $current = Get-FVCurrentToken -State $State

    if ($current.Kind -eq 'LParen') {
        $left = ConvertTo-FVCallExpression -State $State -NameToken $identifierToken
        if (Test-FVParseError -Value $left) { return $left }

        $current = Get-FVCurrentToken -State $State
        if ($current.Kind -eq 'Comparator') {
            return (New-FVParseError -Position $current.Position -Message 'Expected logical operator or end of predicate after function call.')
        }
    }

    if ($current.Kind -eq 'Comparator') {
        return (ConvertTo-FVComparison -State $State -Left $left)
    }

    return $left
}

function ConvertTo-FVCallExpression {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$NameToken
    )

    $openToken = Move-FVToken -State $State
    $arguments = [System.Collections.Generic.List[object]]::new()
    $current = Get-FVCurrentToken -State $State

    if ($current.Kind -eq 'RParen') {
        $null = Move-FVToken -State $State
        return (New-FVCallNode -NameToken $NameToken -Arguments $arguments.ToArray())
    }

    while ($true) {
        $current = Get-FVCurrentToken -State $State
        if ($current.Kind -eq 'EOF') {
            return (New-FVParseError -Position $openToken.Position -Message "Unclosed '('.")
        }

        if ($current.Kind -in @('Comma', 'RParen')) {
            return (New-FVParseError -Position $current.Position -Message 'Expected literal in function call.')
        }

        $argument = ConvertTo-FVLiteral -State $State -Context 'Expected literal in function call.'
        if (Test-FVParseError -Value $argument) { return $argument }
        $arguments.Add($argument)

        $current = Get-FVCurrentToken -State $State
        if ($current.Kind -eq 'Comma') {
            $commaToken = Move-FVToken -State $State
            $next = Get-FVCurrentToken -State $State
            if ($next.Kind -eq 'EOF') {
                return (New-FVParseError -Position $openToken.Position -Message "Unclosed '('.")
            }

            if ($next.Kind -eq 'RParen') {
                return (New-FVParseError -Position $commaToken.Position -Message "Expected literal after ','.")
            }

            continue
        }

        if ($current.Kind -eq 'RParen') {
            $null = Move-FVToken -State $State
            return (New-FVCallNode -NameToken $NameToken -Arguments $arguments.ToArray())
        }

        if ($current.Kind -eq 'EOF') {
            return (New-FVParseError -Position $openToken.Position -Message "Unclosed '('.")
        }

        return (New-FVParseError -Position $current.Position -Message "Expected ',' or ')' in function call.")
    }
}

function ConvertTo-FVComparison {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Left
    )

    $current = Get-FVCurrentToken -State $State
    if ($current.Kind -ne 'Comparator') {
        return (New-FVParseError -Position $current.Position -Message "Expected comparator after identifier '$($Left.Name)'.")
    }

    $operatorToken = Move-FVToken -State $State
    $literal = ConvertTo-FVLiteral -State $State -Context "Expected literal after '$($operatorToken.Value)'."
    if (Test-FVParseError -Value $literal) {
        if ((Get-FVCurrentToken -State $State).Kind -eq 'EOF') {
            return (New-FVParseError -Position (Get-FVCurrentToken -State $State).Position -Message "Missing right-hand literal for '$($operatorToken.Value)'.")
        }

        return $literal
    }

    return (New-FVComparisonNode -Left $Left -Operator $operatorToken.Value -Right $literal -Position $operatorToken.Position)
}

function ConvertTo-FVLiteral {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Context
    )

    $current = Get-FVCurrentToken -State $State
    switch ($current.Kind) {
        'String' {
            $token = Move-FVToken -State $State
            return (New-FVScalarLiteralNode -LiteralType 'String' -Value $token.Value -Position $token.Position)
        }
        'Number' {
            $token = Move-FVToken -State $State
            return (New-FVScalarLiteralNode -LiteralType 'Number' -Value $token.Value -Position $token.Position)
        }
        'Boolean' {
            $token = Move-FVToken -State $State
            return (New-FVScalarLiteralNode -LiteralType 'Boolean' -Value $token.Value -Position $token.Position)
        }
        'LBracket' {
            return (ConvertTo-FVArrayLiteral -State $State)
        }
        default {
            return (New-FVParseError -Position $current.Position -Message $Context)
        }
    }
}

function ConvertTo-FVArrayLiteral {
    param([Parameter(Mandatory)]$State)

    $openToken = Move-FVToken -State $State
    $items = [System.Collections.Generic.List[object]]::new()
    $current = Get-FVCurrentToken -State $State

    if ($current.Kind -eq 'RBracket') {
        $null = Move-FVToken -State $State
        return (New-FVArrayLiteralNode -Items $items.ToArray() -Position $openToken.Position)
    }

    while ($true) {
        $current = Get-FVCurrentToken -State $State
        if ($current.Kind -eq 'EOF') {
            return (New-FVParseError -Position $openToken.Position -Message "Unclosed '['.")
        }

        if ($current.Kind -in @('Comma', 'RBracket')) {
            return (New-FVParseError -Position $current.Position -Message 'Expected literal in array.')
        }

        $item = ConvertTo-FVLiteral -State $State -Context 'Expected literal in array.'
        if (Test-FVParseError -Value $item) { return $item }
        $items.Add($item)

        $current = Get-FVCurrentToken -State $State
        if ($current.Kind -eq 'Comma') {
            $commaToken = Move-FVToken -State $State
            $next = Get-FVCurrentToken -State $State
            if ($next.Kind -eq 'EOF') {
                return (New-FVParseError -Position $openToken.Position -Message "Unclosed '['.")
            }

            if ($next.Kind -eq 'RBracket') {
                return (New-FVParseError -Position $commaToken.Position -Message "Expected literal after ','.")
            }

            continue
        }

        if ($current.Kind -eq 'RBracket') {
            $null = Move-FVToken -State $State
            return (New-FVArrayLiteralNode -Items $items.ToArray() -Position $openToken.Position)
        }

        if ($current.Kind -eq 'EOF') {
            return (New-FVParseError -Position $openToken.Position -Message "Unclosed '['.")
        }

        return (New-FVParseError -Position $current.Position -Message "Expected ',' or ']' in array.")
    }
}

function Test-FVExpressionStructure {
    param([Parameter(Mandatory)]$Node)

    if (Test-FVParseError -Value $Node) { return $Node }
    if ($null -eq $Node -or $null -eq $Node.PSObject.Properties['Kind']) {
        return (New-FVParseError -Position 0 -Message 'Internal parser error: missing AST node kind.')
    }

    switch ($Node.Kind) {
        'Comparison' {
            if ($null -eq $Node.Left -or $Node.Left.Kind -ne 'Identifier') {
                return (New-FVParseError -Position $Node.Position -Message 'Internal parser error: comparison left side must be an identifier.')
            }

            if ($Node.Operator -notin @('==', '!=', '<', '>', '<=', '>=', 'in')) {
                return (New-FVParseError -Position $Node.Position -Message "Internal parser error: unsupported comparator '$($Node.Operator)'.")
            }

            if ($null -eq $Node.Right -or $Node.Right.Kind -ne 'Literal') {
                return (New-FVParseError -Position $Node.Position -Message 'Internal parser error: comparison right side must be a literal.')
            }

            return $true
        }
        'Logical' {
            if ($Node.Operator -notin @('AND', 'OR')) {
                return (New-FVParseError -Position $Node.Position -Message "Internal parser error: unsupported logical operator '$($Node.Operator)'.")
            }

            $leftResult = Test-FVExpressionStructure -Node $Node.Left
            if (Test-FVParseError -Value $leftResult) { return $leftResult }

            $rightResult = Test-FVExpressionStructure -Node $Node.Right
            if (Test-FVParseError -Value $rightResult) { return $rightResult }

            return $true
        }
        'Not' {
            $operandResult = Test-FVExpressionStructure -Node $Node.Operand
            if (Test-FVParseError -Value $operandResult) { return $operandResult }
            return $true
        }
        'Identifier' {
            if ([string]::IsNullOrWhiteSpace($Node.Name)) {
                return (New-FVParseError -Position $Node.Position -Message 'Internal parser error: identifier name is required.')
            }

            return $true
        }
        'Call' {
            if ([string]::IsNullOrWhiteSpace($Node.Name)) {
                return (New-FVParseError -Position $Node.Position -Message 'Internal parser error: function name is required.')
            }

            foreach ($argument in @($Node.Arguments)) {
                if ($null -eq $argument -or $argument.Kind -ne 'Literal') {
                    return (New-FVParseError -Position $Node.Position -Message 'Internal parser error: function arguments must be literals.')
                }
            }

            return $true
        }
        default {
            return (New-FVParseError -Position 0 -Message "Internal parser error: unknown AST node kind '$($Node.Kind)'.")
        }
    }
}

function ConvertTo-FVPredicate {
    [CmdletBinding()]
    param([AllowNull()][string]$Predicate)

    $tokenStream = Get-FVTokens -Predicate $Predicate
    if (Test-FVParseError -Value $tokenStream) { return $tokenStream }

    $state = New-FVParserState -Tokens $tokenStream.Tokens
    $expression = ConvertTo-FVExpression -State $state
    if (Test-FVParseError -Value $expression) { return $expression }

    $current = Get-FVCurrentToken -State $state
    if ($current.Kind -ne 'EOF') {
        switch ($current.Kind) {
            'RParen' {
                return (New-FVParseError -Position $current.Position -Message "Unexpected ')'.")
            }
            'LogicalOperator' {
                return (New-FVParseError -Position $current.Position -Message "Unexpected operator '$($current.Value)'.")
            }
            'Comparator' {
                return (New-FVParseError -Position $current.Position -Message "Unexpected comparator '$($current.Value)'.")
            }
            'Not' {
                return (New-FVParseError -Position $current.Position -Message "Unexpected 'NOT'. Expected logical operator or end of predicate.")
            }
            default {
                return (New-FVParseError -Position $current.Position -Message "Unexpected token '$($current.Value)'.")
            }
        }
    }

    $structureResult = Test-FVExpressionStructure -Node $expression
    if (Test-FVParseError -Value $structureResult) { return $structureResult }

    return $expression
}

function New-FVEvaluationResult {
    param(
        [Parameter(Mandatory)][string]$Result,
        [string]$Reason = ''
    )

    return [PSCustomObject]@{
        Result = $Result
        Reason = $Reason
    }
}

# TODO: refactor candidate — extract `Format-FVBoolResult` helper for the
# `[string]([bool]$x).ToString().ToLowerInvariant()` pattern repeated ~10
# times in this file (sites: Resolve-FVChangesetIdentifierBoolean,
# Resolve-FVCallNode, Resolve-FVComparisonNode). Cosmetic; defer until a
# genuine API need arises.

function Get-FVChangesetField {
    param(
        [Parameter(Mandatory)]$Changeset,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Changeset) { return $null }
    if ($Changeset -is [hashtable] -and $Changeset.ContainsKey($Name)) {
        return $Changeset[$Name]
    }

    $property = $Changeset.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }

    return $null
}

function Get-FVChangedFiles {
    param([Parameter(Mandatory)]$Changeset)

    $value = Get-FVChangesetField -Changeset $Changeset -Name 'ChangedFiles'
    if ($null -eq $value) { return , @() }
    if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $value) { $list.Add($item) }
        return , $list.ToArray()
    }
    return , @($value)
}

function Test-FVAnyPathLike {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Paths,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ($null -eq $Paths) { return $false }

    foreach ($path in $Paths) {
        if ([string]$path -like $Pattern) { return $true }
    }
    return $false
}

function Test-FVAnyPathMatchesPredicate {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Paths,
        [Parameter(Mandatory)][scriptblock]$Predicate
    )

    if ($null -eq $Paths) { return $false }
    foreach ($path in $Paths) {
        if (& $Predicate ([string]$path)) { return $true }
    }
    return $false
}

function Get-FVChangesetComplexity {
    param([Parameter(Mandatory)]$Changeset)

    $totalLinesRaw = Get-FVChangesetField -Changeset $Changeset -Name 'TotalLines'
    $totalLines = 0
    if ($null -ne $totalLinesRaw) {
        $totalLines = [int]$totalLinesRaw
    }

    if ($totalLines -lt 10) { return 'trivial' }
    if ($totalLines -lt 200) { return 'standard' }
    return 'high'
}

function Get-FVDeferredCreditReferenceIdentifiers {
    return @('review.sustainedCriticalOrHigh', 'ceGate.defectsFound')
}

function Get-FVHeuristicDeferredIdentifiers {
    return @('changeset.touchedAreaHasRefactorableDebt')
}

function Get-FVSupportedChangesetIdentifiers {
    return @(
        'changeset.touches',
        'changeset.touchesSource',
        'changeset.touchesTestableCode',
        'changeset.changesBehaviorOrInterface',
        'changeset.touchesCliSurface',
        'changeset.touchesBrowserSurface',
        'changeset.touchesCanvasSurface',
        'changeset.touchesApiSurface',
        'changeset.touchesPluginEntryPoint',
        'changeset.totalLines',
        'changeset.complexity',
        'scope.isReReview',
        'scope.isProxyGithub'
    )
}

function Get-FVPluginEntryPointPatterns {
    return @(
        'agents/*',
        'agents\*',
        'skills/*',
        'skills\*',
        'commands/*',
        'commands\*',
        'hooks/*',
        'hooks\*',
        '.claude-plugin/*',
        '.claude-plugin\*',
        'plugin.json',
        'README.md',
        '.github/copilot-instructions.md',
        '.github\copilot-instructions.md'
    )
}

function Test-FVPathIsDoc {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -like '*.md') { return $true }
    if ($Path -like 'Documents/*' -or $Path -like 'Documents\*') { return $true }
    return $false
}

function Test-FVPathIsTest {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -like '*Tests/*' -or $Path -like '*Tests\*') { return $true }
    return $false
}

function Test-FVPathIsTempArtifact {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -like '.tmp-*' -or $Path -like '*/.tmp-*' -or $Path -like '*\.tmp-*') { return $true }
    return $false
}

function Resolve-FVChangesetIdentifierBoolean {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Changeset
    )

    $paths = Get-FVChangedFiles -Changeset $Changeset

    switch ($Name) {
        'changeset.touchesSource' {
            $hit = Test-FVAnyPathMatchesPredicate -Paths $paths -Predicate {
                param($p)
                if (Test-FVPathIsDoc -Path $p) { return $false }
                if (Test-FVPathIsTest -Path $p) { return $false }
                if (Test-FVPathIsTempArtifact -Path $p) { return $false }
                return $true
            }
            return (New-FVEvaluationResult -Result ([string]([bool]$hit).ToString().ToLowerInvariant()))
        }
        'changeset.touchesTestableCode' {
            $hit = Test-FVAnyPathMatchesPredicate -Paths $paths -Predicate {
                param($p)
                if ($p -notlike '*.ps1') { return $false }
                if (Test-FVPathIsTest -Path $p) { return $false }
                return $true
            }
            return (New-FVEvaluationResult -Result ([string]([bool]$hit).ToString().ToLowerInvariant()))
        }
        'changeset.changesBehaviorOrInterface' {
            if ($paths.Count -eq 0) { return (New-FVEvaluationResult -Result 'false') }
            $allDocs = $true
            foreach ($p in $paths) {
                if (-not ([string]$p -like '*.md')) { $allDocs = $false; break }
            }
            $result = if ($allDocs) { 'false' } else { 'true' }
            return (New-FVEvaluationResult -Result $result)
        }
        'changeset.touchesCliSurface' {
            $hit = Test-FVAnyPathMatchesPredicate -Paths $paths -Predicate {
                param($p)
                if ($p -like 'commands/*' -or $p -like 'commands\*') { return $true }
                if ($p -like '.github/scripts/*.ps1' -or $p -like '.github\scripts\*.ps1') {
                    if ($p -like '.github/scripts/lib/*' -or $p -like '.github\scripts\lib\*') { return $false }
                    if ($p -like '.github/scripts/Tests/*' -or $p -like '.github\scripts\Tests\*') { return $false }
                    return $true
                }
                return $false
            }
            return (New-FVEvaluationResult -Result ([string]([bool]$hit).ToString().ToLowerInvariant()))
        }
        'changeset.touchesBrowserSurface' {
            $hit = Test-FVAnyPathMatchesPredicate -Paths $paths -Predicate {
                param($p)
                return ($p -like '*.html' -or $p -like '*.tsx' -or $p -like '*.css')
            }
            return (New-FVEvaluationResult -Result ([string]([bool]$hit).ToString().ToLowerInvariant()))
        }
        'changeset.touchesCanvasSurface' {
            return (New-FVEvaluationResult -Result 'false')
        }
        'changeset.touchesApiSurface' {
            return (New-FVEvaluationResult -Result 'false')
        }
        'changeset.touchesPluginEntryPoint' {
            $patterns = Get-FVPluginEntryPointPatterns
            $hit = $false
            foreach ($p in $paths) {
                foreach ($pattern in $patterns) {
                    if ([string]$p -like $pattern) { $hit = $true; break }
                }
                if ($hit) { break }
            }
            return (New-FVEvaluationResult -Result ([string]([bool]$hit).ToString().ToLowerInvariant()))
        }
        'scope.isReReview' {
            $value = Get-FVChangesetField -Changeset $Changeset -Name 'IsReReview'
            $bool = [bool]$value
            return (New-FVEvaluationResult -Result ([string]$bool.ToString().ToLowerInvariant()))
        }
        'scope.isProxyGithub' {
            $value = Get-FVChangesetField -Changeset $Changeset -Name 'IsProxyGithub'
            $bool = [bool]$value
            return (New-FVEvaluationResult -Result ([string]$bool.ToString().ToLowerInvariant()))
        }
        default {
            return $null
        }
    }
}

function Resolve-FVCallNode {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Changeset
    )

    $name = $Node.Name
    if ($name -eq 'changeset.touches') {
        $arguments = @($Node.Arguments)
        if ($arguments.Count -lt 1 -or $arguments[0].LiteralType -ne 'String') {
            return (New-FVEvaluationResult -Result 'unknown' -Reason "unsupported-identifier: changeset.touches requires a string glob argument")
        }
        $glob = [string]$arguments[0].Value
        $paths = Get-FVChangedFiles -Changeset $Changeset
        $hit = Test-FVAnyPathLike -Paths $paths -Pattern $glob
        return (New-FVEvaluationResult -Result ([string]([bool]$hit).ToString().ToLowerInvariant()))
    }

    if ($name -in (Get-FVDeferredCreditReferenceIdentifiers)) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason "deferred-credit-reference-identifier: '$name'")
    }

    if ($name -in (Get-FVHeuristicDeferredIdentifiers)) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason "heuristic-deferred: '$name'")
    }

    return (New-FVEvaluationResult -Result 'unknown' -Reason "unsupported-identifier: '$name'")
}

function Resolve-FVIdentifierAsBoolean {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Changeset
    )

    $name = $Node.Name

    if ($name -in (Get-FVDeferredCreditReferenceIdentifiers)) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason "deferred-credit-reference-identifier: '$name'")
    }

    if ($name -in (Get-FVHeuristicDeferredIdentifiers)) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason "heuristic-deferred: '$name'")
    }

    $resolved = Resolve-FVChangesetIdentifierBoolean -Name $name -Changeset $Changeset
    if ($null -ne $resolved) { return $resolved }

    return (New-FVEvaluationResult -Result 'unknown' -Reason "unsupported-identifier: '$name'")
}

function Resolve-FVIdentifierForComparison {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Changeset
    )

    $name = $Node.Name

    if ($name -in (Get-FVDeferredCreditReferenceIdentifiers)) {
        return [PSCustomObject]@{ Status = 'unknown'; Reason = "deferred-credit-reference-identifier: '$name'"; Value = $null }
    }

    if ($name -in (Get-FVHeuristicDeferredIdentifiers)) {
        return [PSCustomObject]@{ Status = 'unknown'; Reason = "heuristic-deferred: '$name'"; Value = $null }
    }

    switch ($name) {
        'changeset.totalLines' {
            $raw = Get-FVChangesetField -Changeset $Changeset -Name 'TotalLines'
            $value = if ($null -eq $raw) { 0 } else { [int]$raw }
            return [PSCustomObject]@{ Status = 'value'; Reason = ''; Value = $value; ValueType = 'Number' }
        }
        'changeset.complexity' {
            $value = Get-FVChangesetComplexity -Changeset $Changeset
            return [PSCustomObject]@{ Status = 'value'; Reason = ''; Value = $value; ValueType = 'String' }
        }
        'scope.isReReview' {
            $raw = Get-FVChangesetField -Changeset $Changeset -Name 'IsReReview'
            return [PSCustomObject]@{ Status = 'value'; Reason = ''; Value = [bool]$raw; ValueType = 'Boolean' }
        }
        'scope.isProxyGithub' {
            $raw = Get-FVChangesetField -Changeset $Changeset -Name 'IsProxyGithub'
            return [PSCustomObject]@{ Status = 'value'; Reason = ''; Value = [bool]$raw; ValueType = 'Boolean' }
        }
        default {
            $resolved = Resolve-FVChangesetIdentifierBoolean -Name $name -Changeset $Changeset
            if ($null -ne $resolved) {
                $b = ($resolved.Result -eq 'true')
                return [PSCustomObject]@{ Status = 'value'; Reason = ''; Value = $b; ValueType = 'Boolean' }
            }
            return [PSCustomObject]@{ Status = 'unknown'; Reason = "unsupported-identifier: '$name'"; Value = $null }
        }
    }
}

function Get-FVLiteralComparisonValue {
    param([Parameter(Mandatory)]$LiteralNode)

    switch ($LiteralNode.LiteralType) {
        'Number' { return [PSCustomObject]@{ Value = [double]$LiteralNode.Value; Type = 'Number' } }
        'String' { return [PSCustomObject]@{ Value = [string]$LiteralNode.Value; Type = 'String' } }
        'Boolean' { return [PSCustomObject]@{ Value = [bool]$LiteralNode.Value; Type = 'Boolean' } }
        default { return $null }
    }
}

function Invoke-FVComparison {
    param(
        [Parameter(Mandatory)][string]$Operator,
        [Parameter(Mandatory)]$LeftValue,
        [Parameter(Mandatory)]$LeftType,
        [Parameter(Mandatory)]$RightValue,
        [Parameter(Mandatory)]$RightType
    )

    if ($LeftType -eq 'Number') { $left = [double]$LeftValue } else { $left = $LeftValue }
    if ($RightType -eq 'Number') { $right = [double]$RightValue } else { $right = $RightValue }

    switch ($Operator) {
        '==' { return ($left -eq $right) }
        '!=' { return ($left -ne $right) }
        '<' { return ($left -lt $right) }
        '>' { return ($left -gt $right) }
        '<=' { return ($left -le $right) }
        '>=' { return ($left -ge $right) }
        default { return $null }
    }
}

function Resolve-FVComparisonNode {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Changeset
    )

    $leftResolved = Resolve-FVIdentifierForComparison -Node $Node.Left -Changeset $Changeset
    if ($leftResolved.Status -eq 'unknown') {
        return (New-FVEvaluationResult -Result 'unknown' -Reason $leftResolved.Reason)
    }

    $right = $Node.Right
    if ($null -eq $right -or $right.Kind -ne 'Literal') {
        return (New-FVEvaluationResult -Result 'unknown' -Reason "parse-error: comparison right-hand side must be a literal")
    }

    if ($right.LiteralType -eq 'Array') {
        if ($Node.Operator -ne 'in') {
            return (New-FVEvaluationResult -Result 'unknown' -Reason "unsupported-identifier: array literal only valid with 'in' operator")
        }
        $found = $false
        foreach ($item in @($right.Items)) {
            $itemValue = Get-FVLiteralComparisonValue -LiteralNode $item
            if ($null -eq $itemValue) { continue }
            $cmp = Invoke-FVComparison -Operator '==' -LeftValue $leftResolved.Value -LeftType $leftResolved.ValueType -RightValue $itemValue.Value -RightType $itemValue.Type
            if ($cmp) { $found = $true; break }
        }
        return (New-FVEvaluationResult -Result ([string]([bool]$found).ToString().ToLowerInvariant()))
    }

    $rightValue = Get-FVLiteralComparisonValue -LiteralNode $right
    if ($null -eq $rightValue) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason "parse-error: unsupported literal type")
    }

    $compared = Invoke-FVComparison -Operator $Node.Operator -LeftValue $leftResolved.Value -LeftType $leftResolved.ValueType -RightValue $rightValue.Value -RightType $rightValue.Type
    if ($null -eq $compared) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason "unsupported-identifier: unknown operator '$($Node.Operator)'")
    }

    return (New-FVEvaluationResult -Result ([string]([bool]$compared).ToString().ToLowerInvariant()))
}

function Invoke-FVLogicalAnd {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    if ($Left.Result -eq 'false') { return (New-FVEvaluationResult -Result 'false') }
    if ($Right.Result -eq 'false') { return (New-FVEvaluationResult -Result 'false') }
    if ($Left.Result -eq 'true' -and $Right.Result -eq 'true') { return (New-FVEvaluationResult -Result 'true') }
    $reason = if ($Left.Result -eq 'unknown') { $Left.Reason } else { $Right.Reason }
    return (New-FVEvaluationResult -Result 'unknown' -Reason $reason)
}

function Invoke-FVLogicalOr {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    if ($Left.Result -eq 'true') { return (New-FVEvaluationResult -Result 'true') }
    if ($Right.Result -eq 'true') { return (New-FVEvaluationResult -Result 'true') }
    if ($Left.Result -eq 'false' -and $Right.Result -eq 'false') { return (New-FVEvaluationResult -Result 'false') }
    $reason = if ($Left.Result -eq 'unknown') { $Left.Reason } else { $Right.Reason }
    return (New-FVEvaluationResult -Result 'unknown' -Reason $reason)
}

function Invoke-FVNotResult {
    param([Parameter(Mandatory)]$Operand)

    switch ($Operand.Result) {
        'true' { return (New-FVEvaluationResult -Result 'false') }
        'false' { return (New-FVEvaluationResult -Result 'true') }
        default { return (New-FVEvaluationResult -Result 'unknown' -Reason $Operand.Reason) }
    }
}

function Invoke-FVPredicateEvaluation {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Changeset
    )

    if ($null -eq $Node) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason 'parse-error: AST node is null')
    }

    $kindProperty = $Node.PSObject.Properties['Kind']
    if ($null -eq $kindProperty) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason 'parse-error: missing Kind on AST node')
    }

    switch ($Node.Kind) {
        'Identifier' {
            return (Resolve-FVIdentifierAsBoolean -Node $Node -Changeset $Changeset)
        }
        'Call' {
            return (Resolve-FVCallNode -Node $Node -Changeset $Changeset)
        }
        'Comparison' {
            return (Resolve-FVComparisonNode -Node $Node -Changeset $Changeset)
        }
        'Logical' {
            $left = Invoke-FVPredicateEvaluation -Node $Node.Left -Changeset $Changeset
            $right = Invoke-FVPredicateEvaluation -Node $Node.Right -Changeset $Changeset
            $op = [string]$Node.Operator
            if ($op.ToUpperInvariant() -eq 'AND') {
                return (Invoke-FVLogicalAnd -Left $left -Right $right)
            }
            if ($op.ToUpperInvariant() -eq 'OR') {
                return (Invoke-FVLogicalOr -Left $left -Right $right)
            }
            return (New-FVEvaluationResult -Result 'unknown' -Reason "parse-error: unknown logical operator '$op'")
        }
        'Not' {
            $operand = Invoke-FVPredicateEvaluation -Node $Node.Operand -Changeset $Changeset
            return (Invoke-FVNotResult -Operand $operand)
        }
        'Literal' {
            return (New-FVEvaluationResult -Result 'unknown' -Reason 'parse-error: bare literal cannot be evaluated as predicate')
        }
        default {
            return (New-FVEvaluationResult -Result 'unknown' -Reason "parse-error: unknown node kind '$($Node.Kind)'")
        }
    }
}

function Test-FVPredicateAgainstChangeset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Ast,
        [Parameter(Mandatory)]$Changeset
    )

    if ($null -eq $Ast) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason 'parse-error: AST is null')
    }

    if (Test-FVParseError -Value $Ast) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason "parse-error: $($Ast.Message)")
    }

    if ($null -eq $Ast.PSObject.Properties['Kind']) {
        return (New-FVEvaluationResult -Result 'unknown' -Reason 'parse-error: AST is not a recognized node')
    }

    return (Invoke-FVPredicateEvaluation -Node $Ast -Changeset $Changeset)
}
