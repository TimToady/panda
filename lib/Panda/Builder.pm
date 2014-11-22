class Panda::Builder;
use Panda::Common;
use File::Find;
use Shell::Command;

sub topo-sort(@modules, %dependencies) {
    my @order;
    my %color_of = @modules X=> 'not yet visited';
    sub dfs-visit($module) {
        %color_of{$module} = 'visited';
        for %dependencies{$module}.list -> $used {
            if (%color_of{$used} // '') eq 'not yet visited' {
                dfs-visit($used);
            }
        }
        push @order, $module;
    }

    for @modules -> $module {
        if %color_of{$module} eq 'not yet visited' {
            dfs-visit($module);
        }
    }
    @order;
}

sub path-to-module-name($path) {
    my $slash = / [ '/' | '\\' ]  /;
    $path.subst(/^'lib'<$slash>/, '').subst(/^'lib6'<$slash>/, '').subst(/\.pm6?$/, '').subst($slash, '::', :g);
}

sub build-order(@module-files) {
    my @modules = map { path-to-module-name($_) }, @module-files;
    my %module-to-path = @modules Z=> @module-files;
    my %usages_of;
    for @module-files -> $module-file {
        my $module = path-to-module-name($module-file);
        %usages_of{$module} = [];
        next unless $module-file.Str ~~ /\.pm6?$/; # don't try to "parse" non-perl files
        my $fh = open($module-file.Str, :r);
        for $fh.lines() {
            if /^\s* ['use'||'need'||'require'] \s+ (\w+ ['::' \w+]*)/ && $0 -> $used {
                next if $used eq 'v6';
                next if $used eq 'MONKEY_TYPING';

                %usages_of{$module}.push(~$used);
            }
        }
        $fh.close;
    }
    my @order = topo-sort(@modules, %usages_of);

    return map { %module-to-path{$_} }, @order;
}

method build($where, :$bone) {
    indir $where, {
        if "Build.pm".IO.f {
            @*INC.push($where);
            GLOBAL::<Build>:delete;
            require 'Build.pm';
            if ::('Build').isa(Panda::Builder) {
                ::('Build').new.build($where);
            }
            @*INC.pop;
        }
        my @files;
        if 'lib'.IO.d {
            @files = find(dir => 'lib', type => 'file').map({
                my $io = .IO;
                $io if $io.basename.substr(0, 1) ne '.';
            });
        }
        my @dirs = @files.map(*.dirname).unique;
        mkpath "blib/$_" for @dirs;

        my @tobuild = build-order(@files);
        withp6lib {
            my $output = '';
            for @tobuild -> $file {
                $file.copy: "blib/$file";
                next unless $file ~~ /\.pm6?$/;
                my $dest = "blib/{$file.dirname}/"
                         ~ $file.basename ~ '.' ~ compsuffix ;
                #note "$dest modified: ", $dest.IO.modified;
                #note "$file modified: ", $file.IO.modified;
                #if $dest.IO.modified >= $file.IO.modified {
                #    say "$file already compiled, skipping";
                #    next;
                #}
                say "Compiling $file to {comptarget}";
                my $cmd    = "$*EXECUTABLE --target={comptarget} "
                           ~ "--output=$dest $file";
                $output ~= "$cmd\n";
                my $handle = pipe($cmd, :r);
                for $handle.lines {
                    .chars && .say;
                    $output ~= "$_\n";
                }
                my $passed = $handle.close.status == 0;

                if $bone {
                    $bone.build-output = $output;
                    $bone.build-passed = $passed;
                }
                fail "Failed building $file" unless $passed;
            }
            1;
        }
        1;
    };
    return True;
}

# vim: ft=perl6
