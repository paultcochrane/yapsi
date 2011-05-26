use v6;

#NIECZA
{
    use MONKEY_TYPING;
    augment class List {
        method kv() { my $i = 0; self.map({ $i++, $_ }) }
    }
    augment class Match {
        method keys () { %(self).keys }
    }
}

my $VERSION = '2011.05';

my $_PROGRAM; # RAKUDO: Part of workaround required because of [perl #76894]

# At any given time, @blockstack contains the chain of blocks we're in,
# from the outermost (the main program body), to the innermost. Each block
# is stored as a FUTURE_Block, with the keys :name :vars, though :vars is
# only filled in at the time of the action method at the end of the parsing of
# the block.
my @blockstack;

class FUTURE_Block { ... }

my %block-parents;

grammar Yapsi::Perl6::Grammar {
    regex TOP { ^
                { %block-parents = ();
                  push @blockstack,
                       FUTURE_Block.new( :name(unique-block()) ) }
                <statementlist> <.ws> $ }
    token block { <.ws> '{'
                  { push @blockstack,
                         FUTURE_Block.new( :name(unique-block()) ) }
                  <.ws> <statementlist> <.ws> '}' }
    regex statementlist { <statement> ** <eat_terminator> }
    token statement { <statement_control> || <expression> || '' }
    # RAKUDO: <?after '}'> NYRI [perl #76894]
    regex eat_terminator { <?{ $/.CURSOR.pos > 0
                               && $_PROGRAM.substr($/.CURSOR.pos - 1, 1) eq '}'
                           }> \n
                           || <.ws> ';' }
    token statement_control { <statement_control_if>
                              || <statement_control_unless>
                              || <statement_control_while>
                              || <statement_control_until> }
    rule  statement_control_if { 'if' <expression> <block>
                                 [ 'else' <else=.block> ]? }
    rule  statement_control_unless { 'unless' <expression> <block> }
    rule  statement_control_while { 'while' <expression> <block> }
    rule  statement_control_until { 'until' <expression> <block> }

    token expression { <assignment> || <binding> || <variable> || <literal>
                       || <declaration> || <invocation> || <block> || <phaser>
                       || <saycall> || <subcall> || <increment> || <decrement>
                     }
    rule phaser { 'ENTER' <block> }
    token lvalue { <declaration> || <variable> || <increment> }
    token value { <variable> || <literal> || <declaration> || <saycall>
                  || <increment> }
    rule  declaration {
        <subdecl>
        || $<declarator>=['my'|'our']
           [<subdecl> || <variable> ||
            { die "Malformed $<declarator>" }]

    }
    rule  subdecl { 'sub' $<subname>=[\w+] <block> }

    token variable { '$' \w+ }
    token literal { \d+ }
    rule  assignment { <lvalue> '=' <expression> }
    rule  binding { <lvalue> ':=' <expression> }
    rule  saycall { 'say' <expression> }  # very temporary solution
    rule  subcall { $<subname>=[\w+]'()'? }
    rule  increment { '++' <value> }
    rule  decrement { '--' <value> }
    rule  invocation { [<variable>||<block>]'()' }
}

my $block-number = 0;   # Can be done with 'state' when Rakudo has it
sub unique-block() {
    'B' ~ $block-number++;
}

class FUTURE_Node {
    has FUTURE_Node @.children is rw;

    method push(*@nodes) {
        @!children.push(|@nodes);
        return self;
    }

    method at_pos($index) {
        return @!children.at_pos($index);
    }

    method DEBUG() {
        sub helper($node, $index) {
            take [~] '  ' x $index,
                     $node.WHAT.perl.subst(/^ .*? '::'/, ''),
                     ($node.^can("info") ?? $node.info !! "");
            if $node.^can("children") {
                helper($_, $index + 1) for $node.children;
            }
        }

        return gather {
            helper(self, 0);
        }
    }
}

class FUTURE_Block is FUTURE_Node {
    has $.name;
    has @.vars is rw;
    has $.immediate is rw;
    has $.phaser is rw;

    method info { [~] ' -- ', $.name,
                      (' [', @.vars.map(*.<name>).join(', '), ']' if @.vars) }
}

class FUTURE_Var   is FUTURE_Node {
    has $.name;

    method info { " -- $.name()" }
}

class FUTURE_Val   is FUTURE_Node {
    has $.value;

    method info { " -- $.value()" }
}

class FUTURE_Op    is FUTURE_Node {}

class FUTURE_Call  is FUTURE_Op {
    has $.name;

    method info { " -- $.name()" }
}

class FUTURE_Assign is FUTURE_Op {}
class FUTURE_Bind   is FUTURE_Op {}
class FUTURE_If     is FUTURE_Op {}
class FUTURE_Unless is FUTURE_Op {}
class FUTURE_While  is FUTURE_Op {}
class FUTURE_Until  is FUTURE_Op {}

sub traverse-top-down(Match $m, :$key = "TOP", :&action, :@skip) {
    action($m, $key);
    for %($m).keys -> $key {
        next if grep * eq $key, @skip;
        given $m{$key} {
            when Match { traverse-top-down($_, :$key, :&action, :@skip) }
            when List  { traverse-top-down($_, :$key, :&action, :@skip)
                            for .list }
            default { die "Unknown thing $m.keys() / $key / $_.typename() in parse tree!" }
        }
    }
}

class Yapsi::Perl6::Actions {

    # At any given time, %!vars maps each 'active' (currently lexically
    # visible) variable to the name of the block containing its outermost
    # declaration.
    has %!vars;

    sub hoist($/, @subnodes) {
        for @subnodes {
            if $/{$_} {
                make $/{$_}.ast;
                return;
            }
        }
        die "Couldn't hoist $/.keys.join(' '), not among {@subnodes}";
    }

    method TOP($/) {
        self.block($/);
    }

    # As opposed to %!vars with its parse-global reach, @vars only has meaning
    # within the .block method. It enumerates all of the variables declared
    # directly in the current block. We need to clone the Array each time we
    # store it, because we keep re-using the variable.
    my @vars;
    my &find-declarations = sub ($m, $key) {
        if $key eq "declaration" {
            my $name = $m<variable> ?? ~$m<variable>
                                    !! '&' ~ $m<subdecl><subname>;
            my $our = $m<declarator> eq 'our';
            push @vars, { :$name, :$our };
        }
    };

    method block($/) {
        @vars = ();
        traverse-top-down($/, :skip['block'], :action(&find-declarations));
        # Replace the pretender Block on the stack with a real one
        my $block = @blockstack.pop;
        my $name = $block.name;
        $block.vars = @vars.list;
        $block.children.push($<statementlist><statement>.map(*.ast).grep(*.defined));
        make $block;
        if @blockstack {
            %block-parents{$name} = @blockstack[*-1];
        }
        # RAKUDO: Can't assign to a hash when the hash is part of the rhs
        #         [perl #77586]
        my %workaround-vars = grep { .value ne $name }, %!vars;
        %!vars = %workaround-vars;
        if first { .value eq 'declaration?' }, %!vars -> $p {
            die qq[Variable "$p.key()" used but not declared];
        }
    }

    method statement($/) {
        if $<expression> && $<expression><block> -> $e {
            my $block = $e.ast;
            $block.immediate = True;
        }

        if $<expression> {
            make $<expression>.ast;
        }
        elsif $<statement_control> {
            make $<statement_control>.ast;
        }
        else { # the '' case
            make FUTURE_Val.new(:value("Any"));    # we don't have Nil yet
        }
    }

    method statement_control($/) {
        hoist $/, (<statement_control_if statement_control_unless
                    statement_control_while statement_control_until>);
    }

    method statement_control_if($/) {
        make FUTURE_If.new(:children($<expression>.ast,
                                      $<block>.ast,
                                      ($<else>[0].^can('ast') ?? $<else>[0].ast !! ())));
    }

    method statement_control_unless($/) {
        make FUTURE_Unless.new(:children($<expression>.ast,
                                          $<block>.ast));
    }

    method statement_control_while($/) {
        make FUTURE_While.new(:children($<expression>.ast,
                                         $<block>.ast));
    }

    method statement_control_until($/) {
        make FUTURE_Until.new(:children($<expression>.ast,
                                         $<block>.ast));
    }

    method expression($/) {
        hoist $/, (<assignment literal saycall subcall variable declaration
                    binding increment decrement invocation block phaser>);
    }

    method phaser($/) {
        hoist $/, ('block', );
        $/.ast.phaser = True;
    }

    method lvalue($/) {
        hoist $/, (<declaration variable increment decrement>);
    }

    method value($/) {
        hoist $/, (<variable declaration>);
    }

    # The reason we temporarily store 'declaration?' in %!vars is that in a
    # bottom-up model such as the one the actions employ, <variable> fires
    # before <declaration>. Basically, there needs to be a way to say "this
    # may be an undeclared variable, or maybe a variable that is being
    # declared". The two possible cases of the former are caught in the
    # .variable and .block methods.

    method declaration($/) {
        if $<variable> {
            if %!vars{~$<variable>} eq 'declaration?' {
                %!vars{~$<variable>} = @blockstack[*-1].name;
            }

            make $<variable>.ast;
        }
        else {  # subdecl
            my $name = '&' ~ $<subdecl><subname>;
            %!vars{$name} = @blockstack[*-1].name;
            my $bind = FUTURE_Bind.new();
            $bind.children.push(
                FUTURE_Var.new(:$name),
                $<subdecl><block>.ast
            );
            @blockstack[*-1].children.push($bind);
        }
    }

    method variable($/) {
        die qq[Variable "$/" used but not declared]
            if %!vars{~$/} eq 'declaration?';
        unless %!vars{~$/}:exists { #NIECZA: no .exists method
            %!vars{~$/} = 'declaration?';
        }

        make FUTURE_Var.new(:name(~$/));
    }

    method literal($/) {
        make FUTURE_Val.new(:value(~$/));
    }

    method assignment($/) {
        make FUTURE_Assign.new(:children($<lvalue>.ast, $<expression>.ast));
    }

    method binding($/) {
        make FUTURE_Bind.new(:children($<lvalue>.ast, $<expression>.ast));
    }

    method saycall($/) {
        make FUTURE_Call.new(:name('&say'), :children($<expression>.ast));
    }

    method subcall($/) {
        make FUTURE_Call.new(:name('&' ~ $<subname>),
                              :children());
    }

    method increment($/) {
        make FUTURE_Call.new(:name('&prefix:<++>'), :children($<value>.ast));
    }

    method decrement($/) {
        make FUTURE_Call.new(:name('&prefix:<-->'), :children($<value>.ast));
    }

    method invocation($/) {
        make FUTURE_Call.new(
            :name('&postcircumfix:<( )>'),
            :children($<variable> ?? $<variable>.ast !! $<block>.ast)
        );
    }
}

class Yapsi::Compiler {
    has @.warnings;

    method to-future($program) {
        @!warnings = ();
        $_PROGRAM = $program; # RAKUDO: Required because of [perl #76894]
        die "Could not parse"
            unless Yapsi::Perl6::Grammar.parse(
                        $program, :actions(Yapsi::Perl6::Actions.new));
        return $/.ast.DEBUG;
    }

    method compile($program) {
        @!warnings = ();
        $_PROGRAM = $program; # RAKUDO: Required because of [perl #76894]
        die "Could not parse"
            unless Yapsi::Perl6::Grammar.parse(
                        $program, :actions(Yapsi::Perl6::Actions.new));
        my @sic = "This is SIC v$VERSION";
        my $INDENT = '    ';
        my %package-variables;

        my @blocksic;

        my $l = 0;
        sub unique-label {
            return 'L' ~ $l++;
        }

        my $r = 0;
        sub unique-register {
            return '$' ~ $r++;
        }

        my $locator;
        my $register;

        my @blocks-to-serialize = $/.ast;
        my @already-serialized;

        while @blocks-to-serialize > @already-serialized {
            my $block = first -> $b { !grep * eq $b, @already-serialized },
                              @blocks-to-serialize;
            serialize $block;
            push @already-serialized, $block;
        }

        if %package-variables {
            push @sic, '';
            push @sic, "block 'GLOBAL':";
            for %package-variables.keys -> $var {
                push @sic, "    `var '$var'";
            }
        }

        return @sic;

        sub serialize(FUTURE_Block $block) {
            push @sic, '';
            push @sic, "block '$block.name()':";
            for $block.vars.list -> $var {
                push @sic, "    `var '$var<name>'"
                           ~ ($var<our> ?? ' :our' !! '');
                if $var<our> {
                    ++%package-variables{$var<name>};
                }
            }

            @blocksic = ();
            my $*current_block = $block;
            for $block.children -> $statement {
                process $statement;
            }
            for renumber declutter @blocksic {
                push @sic, $INDENT ~ $_;
            }
        }

        multi process(FUTURE_Call $call) {
            if $call.children.elems {
                process $call.children[0]; # a FUTURE_Expression
            }

            given $call.name {
                when '&say' {
                    my $result-register = unique-register;
                    push @blocksic, "say $register",
                                    "$result-register = 1";
                    $register = $result-register;
                }
                when '&prefix:<++>' {
                    die "Cannot increment a constant"
                        if $locator eq '<constant>';
                    push @blocksic, "inc $register",
                                    "store $locator, $register";
                }
                when '&prefix:<-->' {
                    die "Cannot decrement a constant"
                        if $locator eq '<constant>';
                    push @blocksic, "dec $register",
                                    "store $locator, $register";
                }
                when '&postcircumfix:<( )>' {
                    push @blocksic, "call $register";
                }
                default {
                    # This is slightly cannibalistic, but still better than
                    # code duplication
                    process FUTURE_Var.new(:name($call.name));
                    push @blocksic, "call $register";
                }
            }
        }

        multi process(FUTURE_Val $val) {
            $register = unique-register;
            my $literal = $val.value;
            push @blocksic, "$register = $literal";
        }

        multi process(FUTURE_Assign $assign) {
            process $assign.children[1];
            my $expression-register = $register;
            process $assign.children[0]; # FUTURE_Var
            $register = $expression-register;
            push @blocksic, "store $locator, $register";
        }

        multi process(FUTURE_Bind $bind) {
            process $bind.children[1];
            my $rightloc = $locator;
            my $expression-register = $register;
            process $bind.children[0]; # FUTURE_Var
            $register = $expression-register;
            if $bind.children[1] ~~ FUTURE_Var {
                push @blocksic, "bind $locator, $rightloc";
            }
            else {
                push @blocksic, "bind $locator, $register";
            }
        }

        multi process(FUTURE_Var $var) {
            $register = unique-register;
            my $b = $*current_block;
            my $level = 0;
            my $slot = -1;
            while True {
                my @vars = $b.vars.list;
                for ^@vars -> $i {
                    if $var.name eq @vars[$i]<name> {
                        $slot = $i;
                        # RAKUDO: Could use a 'last LOOP' here
                        last;
                    }
                }
                last if $slot != -1;
                --$level;
                $b = %block-parents{$b.name};
                die "Variable '$var.name()' used but not declared"
                    unless defined $b;
            }
            $locator = "[$level, $slot]";
            push @blocksic, "$register = fetch $locator";
        }

        multi process(FUTURE_Block $block) {
            $register = unique-register;
            push @blocks-to-serialize, $block
                unless grep * eq $block, @already-serialized;
            if $block.phaser {
                unshift @blocksic,
                    "$register = closure-from-block '$block.name()'",
                    "call $register";
            }
            else {
                push @blocksic,
                    "$register = closure-from-block '$block.name()'";
                if $block.immediate {
                    push @blocksic, "call $register";
                }
            }
        }

        multi process(FUTURE_If $if) {
            process $if.children[0];
            my $after-if = unique-label;
            push @blocksic, "jf $register, $after-if";

            $if.children[1].immediate = True;
            process $if.children[1];

            my $after-else;
            if $if.children[2] {
                $after-else = unique-label;
                push @blocksic, "jmp $after-else";
            }
            push @blocksic, "`label $after-if";
            if $if.children[2] {
                $if.children[2].immediate = True;
                process $if.children[2];
                push @blocksic,
                    "`label $after-else";
            }
        }

        multi process(FUTURE_Unless $unless) {
            process $unless.children[0];
            my $after-unless = unique-label;
            push @blocksic, "jt $register, $after-unless";

            $unless.children[1].immediate = True;
            process $unless.children[1];

            push @blocksic, "`label $after-unless";
        }

        multi process(FUTURE_While $while) {
            my $before-while = unique-label;
            push @blocksic, "`label $before-while";
            process $while.children[0];
            my $after-while = unique-label;
            push @blocksic, "jf $register, $after-while";

            $while.children[1].immediate = True;
            process $while.children[1];

            push @blocksic,
                "jmp $before-while",
                "`label $after-while";
        }

        multi process(FUTURE_Until $until) {
            my $before-until = unique-label;
            push @blocksic, "`label $before-until";
            process $until.children[0];
            my $after-until = unique-label;
            push @blocksic, "jt $register, $after-until";

            $until.children[1].immediate = True;
            process $until.children[1];

            push @blocksic,
                "jmp $before-until",
                "`label $after-until";
        }

        multi process(Any $node) {
            die "No multi 'process' defined for {$node.WHAT.perl}, sorry :/";
        }

        sub declutter(@instructions) {
            my @decluttered;
            for @instructions.kv -> $i, $line {
                # RAKUDO: !~~ doesn't bind $/
                if not $line ~~ / ^ ('$' \d+) ' =' / {
                    push @decluttered, $line;
                }
                else {
                    my $varname = ~$0;
                    my Bool $usages-later = False;
                    for $i+1 ..^ +@instructions -> $j {
                        # XXX: This heuristic fails when we reach many-digit
                        #      reguster names, since it gives false positives
                        #      for all prefixes
                        ++$usages-later
                            if defined @instructions[$j].index($varname);
                    }
                    if $usages-later {
                        push @decluttered, $line;
                    }
                }
            }
            return @decluttered;
        }

        sub renumber(@instructions) {
            my $number = 0;
            my %mapping;
            # RAKUDO: $/ doesn't work in .subst closures
            my $hack;
            return @instructions.map: {
                .subst( :global, / ('$' \d+) { $hack = ~$0 } /, {
                    my $varname = $hack;
                    if !(%mapping{$varname}:exists) { # NIECZA no .exists
                        %mapping{$varname} = '$' ~ $number++;
                    }
                    %mapping{$varname}
                } );
            };
        }
    }
}

class Value {
    has $.payload;

    method store($v) { die "Cannot assign to a readonly value" } #OK
}

class Container {
    has Value $!value;

    method store(Value $v) { $!value = $v }
    method fetch() { $!value }
    method payload() { $!value.defined ?? $!value.payload !! "Any()" }
}

class Lexpad {
    has @.slots;
    has %.names;
    has Lexpad $.outer;

    method Str {
        "lexpad[" ~ %.names.sort({ $^a.value leg $^b.value }).map(*.key).join(", ") ~ "]";
    }
}

class Closure {
    has $.block;
    has Lexpad $.outer;
}

sub find-block(@sic, $name) {
    for @sic.kv -> $n, $line {
        return $n
            if $line ~~ / ^ 'block '\'(<-[']>+)\'':' $ / && $0 eq $name;
    }
    die "Didn't find block $name";
}

sub find-label(@sic, $name) {
    for @sic.kv -> $n, $line {
        return $n
            if $line ~~ / ^ '    `label '(\S+) $ / && $0 eq $name;
    }
    die "Didn't find label $name";
}

class Yapsi::Runtime {
    has Lexpad $.current-lexpad;

    method tick() {}

    method run(@sic) {
        # RAKUDO: Need to use 'not' here rather than '!~~' [perl #76892]
        if not @sic[0] ~~ /^ 'This is SIC v'(\d\d\d\d\.\d\d) $/ {
            die "Incompatible SIC version line";
        }
        elsif ~$0 ne $VERSION {
            die "SIC is $0 but this is $VERSION -- cannot run";
        }

        my @registers-stack = [];
        my @ip-stack;

        sub reg() { @registers-stack[@registers-stack - 1] }
        sub n-up-from($lexpad_, $levels) {
            my $lexpad = $lexpad_;
            $lexpad.=outer for ^$levels;
            die "Went too far and ended up nowhere"
                unless defined $lexpad;
            $lexpad;
        }

        my $global-lexpad;

        sub new-lexpad-from(@sic, $line_, Lexpad $outer?) {
            my $line = $line_;
            my (@vars, @slots);
            # RAKUDO: Some Any()s seem to end up in the @sic array. Hence the
            #         need for prefix:<~>. Would be interesting to learn where
            #         this happens.
            while ~@sic[++$line]
                    ~~ / '    `' (\S*) :s \'(<-[']>+)\' ( ':'\w+)* / {
                given $0 {
                    when "var" {
                        push @vars, ~$1;
                        my $is-our-variable = ?( grep ':our', @($2) );
                        my $container = $is-our-variable
                            ?? (.slots[.names{~$1}] given $global-lexpad)
                            !! Container.new;
                        push @slots, $container;
                    }
                    default { die "Unknown directive $0"; }
                }
            }
            return Lexpad.new(:@slots, :names((my %hash = @vars.kv).invert), :$outer); #OK
        }

        try {
            $global-lexpad
                = new-lexpad-from(@sic, find-block(@sic, 'GLOBAL'));
        }

        $!current-lexpad = new-lexpad-from(@sic, 2);
        self.tick;
        my $ip = 3;
        while @registers-stack {
            while my $line = @sic[$ip++] {
                given substr($line,4) {
                    when / ^ '`' / {}
                    when / ^ '$'(\d+) ' = ' (\d+) $ / { reg[+$0] = +$1 }
                    when / ^ 'store ['[(0)||'-'(\d+)]', '(\d+)'], $'(\d+) $ / {
                        my ($levels, $slot, $register) = +$0, +$1, +$2;
                        my $lexpad = n-up-from($!current-lexpad, $levels);
                        $lexpad.slots[$slot].store(
                            Value.new( :payload(reg[$register]) )
                        );
                        self.tick;
                    }
                    when / ^ '$'(\d+)' = fetch '
                             '['[(0)||'-'(\d+)]', '(\d+)']' $ / {
                        my ($register, $levels, $slot) = +$0, +$1, +$2;
                        my $lexpad = n-up-from($!current-lexpad, $levels);
                        reg[$register] = $lexpad.slots[$slot].payload();
                    }
                    when / ^ 'bind ['[(0)||'-'(\d+)]', '(\d+)'], '
                                  '['[(0)||'-'(\d+)]', '(\d+)']' $ / {
                        my ($var1-levels, $var1-slot) = +$0, +$1;
                        my $var1-lexpad
                            = n-up-from($!current-lexpad, $var1-levels);
                        my ($var2-levels, $var2-slot) = +$2, +$3;
                        my $var2-lexpad
                            = n-up-from($!current-lexpad, $var2-levels);
                        $var1-lexpad.slots[$var1-slot]
                            = $var2-lexpad.slots[$var2-slot];
                        self.tick;
                    }
                    when / ^ 'bind ['[(0)||'-'(\d+)]', '(\d+)'], $'(\d+) $ / {
                        my ($levels, $slot, $register) = +$0, +$1, +$2;
                        my $lexpad = n-up-from($!current-lexpad, $levels);
                        $lexpad.slots[$slot]
                            = Value.new( :payload(reg[$register]) );
                        self.tick;
                    }
                    when / ^ 'inc $'(\d+) $ / {
                        reg[+$0] = reg[+$0] eq 'Any()' ?? 1 !! reg[+$0] + 1;
                    }
                    when / ^ 'dec $'(\d+) $ / {
                        reg[+$0] = reg[+$0] eq 'Any()' ?? 1 !! reg[+$0] - 1;
                    }
                    when / ^ 'jf $'(\d+)', '(\S+) $ / {
                        if reg[+$0] == 0 {
                            $ip = find-label(@sic, ~$1);
                        }
                        self.tick;
                    }
                    when / ^ 'jt $'(\d+)', '(\S+) $ / {
                        if reg[+$0] != 0 {
                            $ip = find-label(@sic, ~$1);
                        }
                        self.tick;
                    }
                    when / ^ 'jmp '(\S+) $ / {
                        $ip = find-label(@sic, ~$0);
                        self.tick;
                    }
                    when / ^ '$'(\d+)' = closure-from-block '
                             \'(<-[']>+)\' $ / {
                        reg[+$0] = Closure.new(:block(~$1),
                                               :outer($!current-lexpad));
                    }
                    when / ^ 'call $'(\d+) $ / {
                        die "Trying to call a non-closure"
                            if (my $closure = reg[+$0]) !~~ Closure;
                        push @registers-stack, [];
                        push @ip-stack, $ip;
                        $ip = find-block(@sic, $closure.block);
                        $!current-lexpad
                            = new-lexpad-from(@sic, $ip, $closure.outer);
                        ++$ip;
                        self.tick;
                    }
                    when / ^ 'say $'(\d+) $ / {
                        say(reg[+$0]);
                        self.tick;
                    }
                    default {
                        die "Unknown instruction: ", $_;
                    }
                }
            }
            pop @registers-stack;
            $ip = pop @ip-stack;
            $!current-lexpad.=outer;
        }
    }
}
