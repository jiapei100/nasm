#!/usr/bin/perl
## --------------------------------------------------------------------------
##
##   Copyright 1996-2012 The NASM Authors - All Rights Reserved
##   See the file AUTHORS included with the NASM distribution for
##   the specific copyright holders.
##
##   Redistribution and use in source and binary forms, with or without
##   modification, are permitted provided that the following
##   conditions are met:
##
##   * Redistributions of source code must retain the above copyright
##     notice, this list of conditions and the following disclaimer.
##   * Redistributions in binary form must reproduce the above
##     copyright notice, this list of conditions and the following
##     disclaimer in the documentation and/or other materials provided
##     with the distribution.
##
##     THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
##     CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
##     INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
##     MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
##     DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
##     CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
##     SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
##     NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
##     LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
##     HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
##     CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
##     OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
##     EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
##
## --------------------------------------------------------------------------

#
# insns.pl
#
# Parse insns.dat and produce generated source code files

# Opcode prefixes which need their own opcode tables
# LONGER PREFIXES FIRST!
@disasm_prefixes = qw(0F24 0F25 0F38 0F3A 0F7A 0FA6 0FA7 0F);

# This should match MAX_OPERANDS from nasm.h
$MAX_OPERANDS = 5;

# Add VEX/XOP prefixes
@vex_class = ( 'vex', 'xop' );
$vex_classes = scalar(@vex_class);
@vexlist = ();
%vexmap = ();
for ($c = 0; $c < $vex_classes; $c++) {
    $vexmap{$vex_class[$c]} = $c;
    for ($m = 0; $m < 32; $m++) {
        for ($p = 0; $p < 4; $p++) {
            push(@vexlist, sprintf("%s%02X%01X", $vex_class[$c], $m, $p));
        }
    }
}
@disasm_prefixes = (@vexlist, @disasm_prefixes);

@bytecode_count = (0) x 256;

print STDERR "Reading insns.dat...\n";

@args   = ();
undef $output;
foreach $arg ( @ARGV ) {
    if ( $arg =~ /^\-/ ) {
        if  ( $arg =~ /^\-([abdin])$/ ) {
            $output = $1;
        } else {
            die "$0: Unknown option: ${arg}\n";
        }
    } else {
        push (@args, $arg);
    }
}

$fname = "insns.dat" unless $fname = $args[0];
open (F, $fname) || die "unable to open $fname";

%dinstables = ();
@bytecode_list = ();

$line = 0;
$insns = 0;
while (<F>) {
    $line++;
    chomp;
    next if ( /^\s*(\;.*|)$/ );   # comments or blank lines

    unless (/^\s*(\S+)\s+(\S+)\s+(\S+|\[.*\])\s+(\S+)\s*$/) {
        warn "line $line does not contain four fields\n";
        next;
    }
    @fields = ($1, $2, $3, $4);
    @field_list = ([@fields, 0]);

    if ($fields[1] =~ /\*/) {
        # This instruction has relaxed form(s)
        if ($fields[2] !~ /^\[/) {
            warn "line $line has an * operand but uses raw bytecodes\n";
            next;
        }

        $opmask = 0;
        @ops = split(/,/, $fields[1]);
        for ($oi = 0; $oi < scalar @ops; $oi++) {
            if ($ops[$oi] =~ /\*$/) {
                if ($oi == 0) {
                    warn "line $line has a first operand with a *\n";
                    next;
                }
                $opmask |= 1 << $oi;
            }
        }

        for ($oi = 1; $oi < (1 << scalar @ops); $oi++) {
            if (($oi & ~$opmask) == 0) {
                my @xops = ();
                my $omask = ~$oi;
                for ($oj = 0; $oj < scalar(@ops); $oj++) {
                    if ($omask & 1) {
                        push(@xops, $ops[$oj]);
                    }
                    $omask >>= 1;
                }
                push(@field_list, [$fields[0], join(',', @xops),
                     $fields[2], $fields[3], $oi]);
            }
        }
    }

    foreach $fptr (@field_list) {
        @fields = @$fptr;
        ($formatted, $nd) = format_insn(@fields);
        if ($formatted) {
            $insns++;
            $aname = "aa_$fields[0]";
            push @$aname, $formatted;
        }
        if ( $fields[0] =~ /cc$/ ) {
            # Conditional instruction
            $k_opcodes_cc{$fields[0]}++;
        } else {
            # Unconditional instruction
            $k_opcodes{$fields[0]}++;
        }
        if ($formatted && !$nd) {
            push @big, $formatted;
            my @sseq = startseq($fields[2], $fields[4]);
            foreach $i (@sseq) {
                if (!defined($dinstables{$i})) {
                    $dinstables{$i} = [];
                }
                push(@{$dinstables{$i}}, $#big);
            }
        }
    }
}

close F;

#
# Generate the bytecode array.  At this point, @bytecode_list contains
# the full set of bytecodes.
#

# Sort by descending length
@bytecode_list = sort { scalar(@$b) <=> scalar(@$a) } @bytecode_list;
@bytecode_array = ();
%bytecode_pos = ();
$bytecode_next = 0;
foreach $bl (@bytecode_list) {
    my $h = hexstr(@$bl);
    next if (defined($bytecode_pos{$h}));

    push(@bytecode_array, $bl);
    while ($h ne '') {
        $bytecode_pos{$h} = $bytecode_next;
        $h = substr($h, 2);
        $bytecode_next++;
    }
}
undef @bytecode_list;

@opcodes    = sort keys(%k_opcodes);
@opcodes_cc = sort keys(%k_opcodes_cc);

if ( !defined($output) || $output eq 'b') {
    print STDERR "Writing insnsb.c...\n";

    open B, ">insnsb.c";

    print B "/* This file auto-generated from insns.dat by insns.pl" .
        " - don't edit it */\n\n";

    print B "#include \"nasm.h\"\n";
    print B "#include \"insns.h\"\n\n";

    print B "const uint8_t nasm_bytecodes[$bytecode_next] = {\n";

    $p = 0;
    foreach $bl (@bytecode_array) {
        printf B "    /* %5d */ ", $p;
        foreach $d (@$bl) {
            printf B "%#o,", $d;
            $p++;
        }
        printf B "\n";
    }
    print B "};\n";

    print B "\n";
    print B "/*\n";
    print B " * Bytecode frequencies (including reuse):\n";
    print B " *\n";
    for ($i = 0; $i < 32; $i++) {
        print B " *";
        for ($j = 0; $j < 256; $j += 32) {
            print B " |" if ($j);
            printf B " %3o:%4d", $i+$j, $bytecode_count[$i+$j];
        }
        print B "\n";
    }
    print B " */\n";

    close B;
}

if ( !defined($output) || $output eq 'a' ) {
    print STDERR "Writing insnsa.c...\n";

    open A, ">insnsa.c";

    print A "/* This file auto-generated from insns.dat by insns.pl" .
        " - don't edit it */\n\n";

    print A "#include \"nasm.h\"\n";
    print A "#include \"insns.h\"\n\n";

    foreach $i (@opcodes, @opcodes_cc) {
        print A "static const struct itemplate instrux_${i}[] = {\n";
        $aname = "aa_$i";
        foreach $j (@$aname) {
            print A "    ", codesubst($j), "\n";
        }
        print A "    ITEMPLATE_END\n};\n\n";
    }
    print A "const struct itemplate * const nasm_instructions[] = {\n";
    foreach $i (@opcodes, @opcodes_cc) {
        print A "    instrux_${i},\n";
    }
    print A "};\n";

    close A;
}

if ( !defined($output) || $output eq 'd' ) {
    print STDERR "Writing insnsd.c...\n";

    open D, ">insnsd.c";

    print D "/* This file auto-generated from insns.dat by insns.pl" .
        " - don't edit it */\n\n";

    print D "#include \"nasm.h\"\n";
    print D "#include \"insns.h\"\n\n";

    print D "static const struct itemplate instrux[] = {\n";
    $n = 0;
    foreach $j (@big) {
        printf D "    /* %4d */ %s\n", $n++, codesubst($j);
    }
    print D "};\n";

    foreach $h (sort(keys(%dinstables))) {
        next if ($h eq ''); # Skip pseudo-instructions
            print D "\nstatic const struct itemplate * const itable_${h}[] = {\n";
        foreach $j (@{$dinstables{$h}}) {
            print D "    instrux + $j,\n";
        }
        print D "};\n";
    }

    @prefix_list = ();
    foreach $h (@disasm_prefixes, '') {
        for ($c = 0; $c < 256; $c++) {
            $nn = sprintf("%s%02X", $h, $c);
            if ($is_prefix{$nn} || defined($dinstables{$nn})) {
                # At least one entry in this prefix table
                push(@prefix_list, $h);
                $is_prefix{$h} = 1;
                last;
            }
        }
    }

    foreach $h (@prefix_list) {
        print D "\n";
        print D "static " unless ($h eq '');
        print D "const struct disasm_index ";
        print D ($h eq '') ? 'itable' : "itable_$h";
        print D "[256] = {\n";
        for ($c = 0; $c < 256; $c++) {
            $nn = sprintf("%s%02X", $h, $c);
            if ($is_prefix{$nn}) {
                die "$fname: ambiguous decoding of $nn\n"
                    if (defined($dinstables{$nn}));
                printf D "    /* 0x%02x */ { itable_%s, -1 },\n", $c, $nn;
            } elsif (defined($dinstables{$nn})) {
                printf D "    /* 0x%02x */ { itable_%s, %u },\n", $c,
                       $nn, scalar(@{$dinstables{$nn}});
            } else {
                printf D "    /* 0x%02x */ { NULL, 0 },\n", $c;
            }
        }
        print D "};\n";
    }

    printf D "\nconst struct disasm_index * const itable_vex[%d][32][4] =\n",
        $vex_classes;
    print D "{\n";
    for ($c = 0; $c < $vex_classes; $c++) {
        print D "    {\n";
        for ($m = 0; $m < 32; $m++) {
            print D "        { ";
            for ($p = 0; $p < 4; $p++) {
                $vp = sprintf("%s%02X%01X", $vex_class[$c], $m, $p);
                printf D "%-15s",
                       ($is_prefix{$vp} ? sprintf("itable_%s,", $vp) : 'NULL,');
            }
            print D "},\n";
        }
        print D "    },\n";
    }
    print D "};\n";

    close D;
}

if ( !defined($output) || $output eq 'i' ) {
    print STDERR "Writing insnsi.h...\n";

    open I, ">insnsi.h";

    print I "/* This file is auto-generated from insns.dat by insns.pl" .
        " - don't edit it */\n\n";
    print I "/* This file in included by nasm.h */\n\n";

    print I "/* Instruction names */\n\n";
    print I "#ifndef NASM_INSNSI_H\n";
    print I "#define NASM_INSNSI_H 1\n\n";
    print I "enum opcode {\n";
    $maxlen = 0;
    foreach $i (@opcodes, @opcodes_cc) {
        print I "\tI_${i},\n";
        $len = length($i);
        $len++ if ( $i =~ /cc$/ ); # Condition codes can be 3 characters long
        $maxlen = $len if ( $len > $maxlen );
    }
    print I "\tI_none = -1\n";
    print I "};\n\n";
    print I "#define MAX_INSLEN ", $maxlen, "\n";
    print I "#define FIRST_COND_OPCODE I_", $opcodes_cc[0], "\n\n";
    print I "#endif /* NASM_INSNSI_H */\n";

    close I;
}

if ( !defined($output) || $output eq 'n' ) {
    print STDERR "Writing insnsn.c...\n";

    open N, ">insnsn.c";

    print N "/* This file is auto-generated from insns.dat by insns.pl" .
        " - don't edit it */\n\n";
    print N "#include \"tables.h\"\n\n";

    print N "const char * const nasm_insn_names[] = {";
    $first = 1;
    foreach $i (@opcodes, @opcodes_cc) {
        print N "," if ( !$first );
        $first = 0;
        $ilower = $i;
        $ilower =~ s/cc$//;             # Remove conditional cc suffix
        $ilower =~ tr/A-Z/a-z/;         # Change to lower case (Perl 4 compatible)
        print N "\n\t\"${ilower}\"";
    }
    print N "\n};\n";
    close N;
}

printf STDERR "Done: %d instructions\n", $insns;

# Count primary bytecodes, for statistics
sub count_bytecodes(@) {
    my $skip = 0;
    foreach my $bc (@_) {
        if ($skip) {
            $skip--;
            next;
        }
        $bytecode_count[$bc]++;
        if ($bc >= 01 && $bc <= 04) {
            $skip = $bc;
        } elsif (($bc & ~03) == 010) {
            $skip = 1;
        } elsif (($bc & ~013) == 0144) {
            $skip = 1;
        } elsif ($bc == 0172 || $bc == 0173) {
            $skip = 1;
        } elsif ($bc >= 0260 && $bc <= 0270) {
            $skip = 2;
        } elsif ($bc == 0330) {
            $skip = 1;
        }
    }
}

sub format_insn($$$$$) {
    my ($opcode, $operands, $codes, $flags, $relax) = @_;
    my $num, $nd = 0;
    my @bytecode;
    my $op, @ops, $opp, @opx, @oppx;

    return (undef, undef) if $operands eq "ignore";

    # format the operands
    $operands =~ s/\*//g;
    $operands =~ s/:/|colon,/g;
    @ops = ();
    if ($operands ne 'void') {
        foreach $op (split(/,/, $operands)) {
            if ($op =~ /^\=([0-9]+)$/) {
                $op = "same_as|$1";
            } else {
                @opx = ();
                foreach $opp (split(/\|/, $op)) {
                    @oppx = ();
                    if ($opp =~ /^(.*[^\d])(8|16|32|64|80|128|256)$/) {
                        my $ox = $1;
                        my $on = $2;
                        if ($ox !~ /^(sbyte|sdword|udword)$/) {
                            $opp = $ox;
                            push(@oppx, "bits$on");
                        }
                    }
                    $opp =~ s/^mem$/memory/;
                    $opp =~ s/^memory_offs$/mem_offs/;
                    $opp =~ s/^imm$/immediate/;
                    $opp =~ s/^([a-z]+)rm$/rm_$1/;
                    $opp =~ s/^rm$/rm_gpr/;
                    $opp =~ s/^reg$/reg_gpr/;
                    push(@opx, $opp, @oppx);
                }
                $op = join('|', @opx);
            }
            push(@ops, $op);
        }
    }

    $num = scalar(@ops);
    while (scalar(@ops) < $MAX_OPERANDS) {
        push(@ops, '0');
    }
    $operands = join(',', @ops);
    $operands =~ tr/a-z/A-Z/;

    # format the flags
    $flags =~ s/,/|IF_/g;
    $flags =~ s/(\|IF_ND|IF_ND\|)//, $nd = 1 if $flags =~ /IF_ND/;
    $flags = "IF_" . $flags;

    @bytecode = (decodify($codes, $relax), 0);
    push(@bytecode_list, [@bytecode]);
    $codes = hexstr(@bytecode);
    count_bytecodes(@bytecode);

    ("{I_$opcode, $num, {$operands}, \@\@CODES-$codes\@\@, $flags},", $nd);
}

#
# Look for @@CODES-xxx@@ sequences and replace them with the appropriate
# offset into nasm_bytecodes
#
sub codesubst($) {
    my($s) = @_;
    my $n;

    while ($s =~ /\@\@CODES-([0-9A-F]+)\@\@/) {
        my $pos = $bytecode_pos{$1};
        if (!defined($pos)) {
            die "$fname: no position assigned to byte code $1\n";
        }
        $s = $` . "nasm_bytecodes+${pos}" . "$'";
    }
    return $s;
}

sub addprefix ($@) {
    my ($prefix, @list) = @_;
    my $x;
    my @l = ();

    foreach $x (@list) {
        push(@l, sprintf("%s%02X", $prefix, $x));
    }

    return @l;
}

#
# Turn a code string into a sequence of bytes
#
sub decodify($$) {
  # Although these are C-syntax strings, by convention they should have
  # only octal escapes (for directives) and hexadecimal escapes
  # (for verbatim bytes)
    my($codestr, $relax) = @_;

    if ($codestr =~ /^\s*\[([^\]]*)\]\s*$/) {
        return byte_code_compile($1, $relax);
    }

    my $c = $codestr;
    my @codes = ();

    unless ($codestr eq 'ignore') {
	while ($c ne '') {
	    if ($c =~ /^\\x([0-9a-f]+)(.*)$/i) {
		push(@codes, hex $1);
		$c = $2;
		next;
	    } elsif ($c =~ /^\\([0-7]{1,3})(.*)$/) {
		push(@codes, oct $1);
		$c = $2;
		next;
	    } else {
		die "$fname: unknown code format in \"$codestr\"\n";
	    }
	}
    }

    return @codes;
}

# Turn a numeric list into a hex string
sub hexstr(@) {
    my $s = '';
    my $c;

    foreach $c (@_) {
        $s .= sprintf("%02X", $c);
    }
    return $s;
}

# Here we determine the range of possible starting bytes for a given
# instruction. We need only consider the codes:
# \[1234]      mean literal bytes, of course
# \1[0123]     mean byte plus register value
# \330         means byte plus condition code
# \0 or \340   mean give up and return empty set
# \34[4567]    mean PUSH/POP of segment registers: special case
# \17[234]     skip is4 control byte
# \26x \270    skip VEX control bytes
sub startseq($$) {
    my ($codestr, $relax) = @_;
    my $word, @range;
    my @codes = ();
    my $c = $codestr;
    my $c0, $c1, $i;
    my $prefix = '';

    @codes = decodify($codestr, $relax);

    while ($c0 = shift(@codes)) {
        $c1 = $codes[0];
        if ($c0 >= 01 && $c0 <= 04) {
            # Fixed byte string
            my $fbs = $prefix;
            while (1) {
                if ($c0 >= 01 && $c0 <= 04) {
                    while ($c0--) {
                        $fbs .= sprintf("%02X", shift(@codes));
                    }
                } else {
                    last;
                }
                $c0 = shift(@codes);
            }

            foreach $pfx (@disasm_prefixes) {
                if (substr($fbs, 0, length($pfx)) eq $pfx) {
                    $prefix = $pfx;
                    $fbs = substr($fbs, length($pfx));
                    last;
                }
            }

            if ($fbs ne '') {
                return ($prefix.substr($fbs,0,2));
            }

            unshift(@codes, $c0);
        } elsif ($c0 >= 010 && $c0 <= 013) {
            return addprefix($prefix, $c1..($c1+7));
        } elsif (($c0 & ~013) == 0144) {
            return addprefix($prefix, $c1, $c1|2);
        } elsif ($c0 == 0330) {
            return addprefix($prefix, $c1..($c1+15));
        } elsif ($c0 == 0 || $c0 == 0340) {
            return $prefix;
        } elsif ($c0 == 0344) {
            return addprefix($prefix, 0x06, 0x0E, 0x16, 0x1E);
        } elsif ($c0 == 0345) {
            return addprefix($prefix, 0x07, 0x17, 0x1F);
        } elsif ($c0 == 0346) {
            return addprefix($prefix, 0xA0, 0xA8);
        } elsif ($c0 == 0347) {
            return addprefix($prefix, 0xA1, 0xA9);
        } elsif (($c0 & ~3) == 0260 || $c0 == 0270) {
            my $c,$m,$wlp;
            $m   = shift(@codes);
            $wlp = shift(@codes);
            $c = ($m >> 6);
            $m = $m & 31;
            $prefix .= sprintf('%s%02X%01X', $vex_class[$c], $m, $wlp & 3);
        } elsif ($c0 >= 0172 && $c0 <= 173) {
            shift(@codes);      # Skip is4 control byte
        } else {
            # We really need to be able to distinguish "forbidden"
            # and "ignorable" codes here
        }
    }
    return $prefix;
}

#
# This function takes a series of byte codes in a format which is more
# typical of the Intel documentation, and encode it.
#
# The format looks like:
#
# [operands: opcodes]
#
# The operands word lists the order of the operands:
#
# r = register field in the modr/m
# m = modr/m
# v = VEX "v" field
# i = immediate
# s = register field of is4/imz2 field
# - = implicit (unencoded) operand
#
# For an operand that should be filled into more than one field,
# enter it as e.g. "r+v".
#
sub byte_code_compile($$) {
    my($str, $relax) = @_;
    my $opr;
    my $opc;
    my @codes = ();
    my $litix = undef;
    my %oppos = ();
    my $i;
    my $op, $oq;
    my $opex;

    my %imm_codes = (
        'ib,s' => 014,  # Signed imm8
        'ib' => 020,    # imm8
        'ib,u' => 024,  # Unsigned imm8
        'iw' => 030,    # imm16
        'ibx' => 0274,  # imm8 sign-extended to opsize
        'iwd' => 034,   # imm16 or imm32, depending on opsize
        'id' => 040,    # imm32
        'idx' => 0254,  # imm32 extended to 64 bits
        'iwdq' => 044,  # imm16/32/64, depending on opsize
        'rel8' => 050,
        'iq' => 054,
        'rel16' => 060,
        'rel' => 064,   # 16 or 32 bit relative operand
        'rel32' => 070,
        'seg' => 074,
        'ibw' => 0140,  # imm16 that can be bytified
        'ibd' => 0150,  # imm32 that can be bytified
        'ibd,s' => 0250 # imm32 that can be bytified, sign extended to 64 bits
    );
    my %imm_codes_bytifiers = (
        'ibw' => 0144,
        'ibd' => 0154,
        'ibd,s' => 0154
    );
    my %plain_codes = (
	'o16' => 0320,		# 16-bit operand size
	'o32' => 0321,		# 32-bit operand size
	'odf' => 0322,		# Operand size is default
	'o64' => 0324,		# 64-bit operand size requiring REX.W
	'o64nw' => 0323,	# Implied 64-bit operand size (no REX.W)
	'a16' => 0310,
	'a32' => 0311,
	'adf' => 0312,		# Address size is default
	'a64' => 0313,
	'!osp' => 0364,
	'!asp' => 0365,
	'f2i' => 0332,		# F2 prefix, but 66 for operand size is OK
	'f3i' => 0333,		# F3 prefix, but 66 for operand size is OK
	'pushseg' => 0344,
	'popseg' => 0345,
	'pushseg2' => 0346,
	'popseg2' => 0347,
	'mustrep' => 0336,
	'mustrepne' => 0337,
	'rex.l' => 0334,
	'norexb' => 0314,
	'norexx' => 0315,
	'norexr' => 0316,
	'norexw' => 0317,
	'repe' => 0335,
	'nohi' => 0325,		# Use spl/bpl/sil/dil even without REX
	'wait' => 0341,		# Needs a wait prefix
	'resb' => 0340,
	'jcc8' => 0370,		# Match only if Jcc possible with single byte
	'jmp8' => 0371,		# Match only if JMP possible with single byte
	'jlen' => 0373, 	# Length of jump
	'hlexr' => 0271,
	'hlenl' => 0272,
	'hle' => 0273,
	# This instruction takes XMM VSIB
	'vsibx' => 0374,
	'vm32x' => 0374,
	'vm64x' => 0374,
	# This instruction takes YMM VSIB
	'vsiby' => 0375,
	'vm32y' => 0375,
	'vm64y' => 0375
    );

    unless ($str =~ /^(([^\s:]*)\:|)\s*(.*\S)\s*$/) {
        die "$fname: $line: cannot parse: [$str]\n";
    }
    $opr = "\L$2";
    $opc = "\L$3";

    my $op = 0;
    for ($i = 0; $i < length($opr); $i++) {
        my $c = substr($opr,$i,1);
        if ($c eq '+') {
            $op--;
        } else {
            if ($relax & 1) {
                $op--;
            }
            $relax >>= 1;
            $oppos{$c} = $op++;
        }
    }

    my $last_imm = 'h';
    my $prefix_ok = 1;
    foreach $op (split(/\s*(?:\s|(?=[\/\\]))/, $opc)) {
	my $pc = $plain_codes{$op};

	if (defined $pc) {
	    # Plain code
	    push(@codes, $pc);
        } elsif ($prefix_ok && $op =~ /^(66|f2|f3|np)$/) {
            # 66/F2/F3 prefix used as an opcode extension, or np = no prefix
            if ($op eq '66') {
                push(@codes, 0361);
            } elsif ($op eq 'f2') {
                push(@codes, 0362);
            } elsif ($op eq 'f3') {
                push(@codes, 0363);
            } else {
                push(@codes, 0360);
            }
        } elsif ($op =~ /^[0-9a-f]{2}$/) {
            if (defined($litix) && $litix+$codes[$litix]+1 == scalar @codes &&
                $codes[$litix] < 4) {
                $codes[$litix]++;
                push(@codes, hex $op);
            } else {
                $litix = scalar(@codes);
                push(@codes, 01, hex $op);
            }
            $prefix_ok = 0;
        } elsif ($op eq '/r') {
            if (!defined($oppos{'r'}) || !defined($oppos{'m'})) {
                die "$fname: $line: $op requires r and m operands\n";
            }
            $opex = (($oppos{'m'} & 4) ? 06 : 0) |
                (($oppos{'r'} & 4) ? 05 : 0);
            push(@codes, $opex) if ($opex);
            push(@codes, 0100 + (($oppos{'m'} & 3) << 3) + ($oppos{'r'} & 3));
            $prefix_ok = 0;
        } elsif ($op =~ m:^/([0-7])$:) {
            if (!defined($oppos{'m'})) {
                die "$fname: $line: $op requires m operand\n";
            }
            push(@codes, 06) if ($oppos{'m'} & 4);
            push(@codes, 0200 + (($oppos{'m'} & 3) << 3) + $1);
            $prefix_ok = 0;
        } elsif ($op =~ /^(vex|xop)(|\..*)$/) {
            my $c = $vexmap{$1};
            my ($m,$w,$l,$p) = (undef,2,undef,0);
            my $has_nds = 0;
            my @subops = split(/\./, $op);
            shift @subops;      # Drop prefix
                foreach $oq (@subops) {
                    if ($oq eq '128' || $oq eq 'l0' || $oq eq 'lz') {
                        $l = 0;
                    } elsif ($oq eq '256' || $oq eq 'l1') {
                        $l = 1;
                    } elsif ($oq eq 'lig') {
                        $l = 2;
                    } elsif ($oq eq 'w0') {
                        $w = 0;
                    } elsif ($oq eq 'w1') {
                        $w = 1;
                    } elsif ($oq eq 'wig') {
                        $w = 2;
                    } elsif ($oq eq 'ww') {
                        $w = 3;
                    } elsif ($oq eq 'p0') {
                        $p = 0;
                    } elsif ($oq eq '66' || $oq eq 'p1') {
                        $p = 1;
                    } elsif ($oq eq 'f3' || $oq eq 'p2') {
                        $p = 2;
                    } elsif ($oq eq 'f2' || $oq eq 'p3') {
                        $p = 3;
                    } elsif ($oq eq '0f') {
                        $m = 1;
                    } elsif ($oq eq '0f38') {
                        $m = 2;
                    } elsif ($oq eq '0f3a') {
                        $m = 3;
                    } elsif ($oq =~ /^m([0-9]+)$/) {
                        $m = $1+0;
                    } elsif ($oq eq 'nds' || $oq eq 'ndd' || $oq eq 'dds') {
                        if (!defined($oppos{'v'})) {
                            die "$fname: $line: vex.$oq without 'v' operand\n";
                        }
                        $has_nds = 1;
                    } else {
                        die "$fname: $line: undefined VEX subcode: $oq\n";
                    }
                }
            if (!defined($m) || !defined($w) || !defined($l) || !defined($p)) {
                die "$fname: $line: missing fields in VEX specification\n";
            }
            if (defined($oppos{'v'}) && !$has_nds) {
                die "$fname: $line: 'v' operand without vex.nds or vex.ndd\n";
            }
            push(@codes, defined($oppos{'v'}) ? 0260+($oppos{'v'} & 3) : 0270,
                 ($c << 6)+$m, ($w << 4)+($l << 2)+$p);
            $prefix_ok = 0;
        } elsif (defined $imm_codes{$op}) {
            if ($op eq 'seg') {
                if ($last_imm lt 'i') {
                    die "$fname: $line: seg without an immediate operand\n";
                }
            } else {
                $last_imm++;
                if ($last_imm gt 'j') {
                    die "$fname: $line: too many immediate operands\n";
                }
            }
            if (!defined($oppos{$last_imm})) {
                die "$fname: $line: $op without '$last_imm' operand\n";
            }
            push(@codes, 05) if ($oppos{$last_imm} & 4);
            push(@codes, $imm_codes{$op} + ($oppos{$last_imm} & 3));
            if (defined $imm_codes_bytifiers{$op}) {
                if (!defined($s_pos)) {
                    die "$fname: $line: $op without a +s byte\n";
                }
                $codes[$s_pos] += $imm_codes_bytifiers{$op};
            }
            $prefix_ok = 0;
        } elsif ($op eq '/is4') {
            if (!defined($oppos{'s'})) {
                die "$fname: $line: $op without 's' operand\n";
            }
            if (defined($oppos{'i'})) {
                push(@codes, 0172, ($oppos{'s'} << 3)+$oppos{'i'});
            } else {
                push(@codes, 05) if ($oppos{'s'} & 4);
                push(@codes, 0174+($oppos{'s'} & 3));
            }
            $prefix_ok = 0;
        } elsif ($op =~ /^\/is4\=([0-9]+)$/) {
            my $imm = $1;
            if (!defined($oppos{'s'})) {
                die "$fname: $line: $op without 's' operand\n";
            }
            if ($imm < 0 || $imm > 15) {
                die "$fname: $line: invalid imm4 value for $op: $imm\n";
            }
            push(@codes, 0173, ($oppos{'s'} << 4) + $imm);
            $prefix_ok = 0;
        } elsif ($op =~ /^([0-9a-f]{2})\+s$/) {
            if (!defined($oppos{'i'})) {
                die "$fname: $line: $op without 'i' operand\n";
            }
            $s_pos = scalar @codes;
            push(@codes, 05) if ($oppos{'i'} & 4);
            push(@codes, $oppos{'i'} & 3, hex $1);
            $prefix_ok = 0;
        } elsif ($op =~ /^([0-9a-f]{2})\+c$/) {
            push(@codes, 0330, hex $1);
            $prefix_ok = 0;
        } elsif ($op =~ /^([0-9a-f]{2})\+r$/) {
            if (!defined($oppos{'r'})) {
                die "$fname: $line: $op without 'r' operand\n";
            }
            push(@codes, 05) if ($oppos{'r'} & 4);
            push(@codes, 010 + ($oppos{'r'} & 3), hex $1);
            $prefix_ok = 0;
        } elsif ($op =~ /^\\([0-7]+|x[0-9a-f]{2})$/) {
            # Escape to enter literal bytecodes
            push(@codes, oct $1);
        } else {
            die "$fname: $line: unknown operation: $op\n";
        }
    }

    return @codes;
}
