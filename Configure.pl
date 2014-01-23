#! perl
# Copyright (C) 2009 The Perl Foundation

use 5.008;
use strict;
use warnings;
use Text::ParseWords;
use Getopt::Long;
use File::Spec;
use Cwd;
use lib 'tools/lib';
use NQP::Configure qw(sorry slurp cmp_rev gen_nqp read_config 
                      fill_template_text fill_template_file
                      system_or_die verify_install);

my $lang = 'Rakudo';
my $lclang = lc $lang;
my $uclang = uc $lang;
my $slash  = $^O eq 'MSWin32' ? '\\' : '/';


MAIN: {
    if (-r 'config.default') {
        unshift @ARGV, shellwords(slurp('config.default'));
    }

    my %config = (perl => $^X);
    my $config_status = "${lclang}_config_status";
    $config{$config_status} = join ' ', map { qq("$_") } @ARGV;

    my $exe = $NQP::Configure::exe;

    my %options;
    GetOptions(\%options, 'help!', 'prefix=s',
                'backends=s', 'no-clean!',
               'gen-nqp:s',
               'gen-moar:s',
               'gen-parrot:s', 'parrot-option=s@',
               'parrot-make-option=s@',
               'make-install!', 'makefile-timing!',
    ) or do {
        print_help();
        exit(1);
    };

    # Print help if it's requested
    if ($options{'help'}) {
        print_help();
        exit(0);
    }

    $options{prefix} ||= 'install';
    $options{prefix} = File::Spec->rel2abs($options{prefix});
    my $prefix         = $options{'prefix'};
    my %known_backends = (parrot => 1, jvm => 1, moar => 1);
    my %letter_to_backend;
    my $default_backend;
    for (keys %known_backends) {
        $letter_to_backend{ substr($_, 0, 1) } = $_;
    }
    my %backends;
    if (defined $options{backends}) {
        $options{backends} = join ",", keys %known_backends
            if uc($options{backends}) eq 'ALL';
        for my $b (split /,\s*/, $options{backends}) {
            $b = lc $b;
            unless ($known_backends{$b}) {
                die "Unknown backend '$b'; Supported backends are: " .
                    join(", ", sort keys %known_backends) .
                    "\n";
            }
            $backends{$b} = 1;
            $default_backend ||= $b;
        }
        unless (%backends) {
            die "--prefix given, but no valid backend?!\n";
        }
    }
    else {
        for my $l (sort keys %letter_to_backend) {
            # TODO: needs .exe/.bat magic on windows?
            if (-x "$prefix/bin/nqp-$l") {
                my $b = $letter_to_backend{$l};
                print "Found $prefix/bin/nqp-$l (backend $b)\n";
                $backends{$b} = 1;
                $default_backend ||= $b;
            }
        }
        if (exists $options{'gen-moar'}) {
            $backends{moar} = 1;
            $default_backend ||= 'moar';
        }
        if (exists $options{'gen-parrot'}) {
            $backends{parrot} = 1;
            $default_backend ||= 'parrot';
        }
        unless (%backends) {
            die "No suitable nqp executables found! Please specify some --backends, or a --prefix that contains nqp-{p,j,m} executables\n";
        }
    }

    # Save options in config.status
    unlink('config.status');
    if (open(my $CONFIG_STATUS, '>', 'config.status')) {
        print $CONFIG_STATUS
            "$^X Configure.pl $config{$config_status} \$*\n";
        close($CONFIG_STATUS);
    }

    $config{prefix} = $prefix;
    $config{slash}  = $slash;
    $config{'makefile-timing'} = $options{'makefile-timing'};
    $config{'stagestats'} = '--stagestats' if $options{'makefile-timing'};
    $config{'cpsep'} = $^O eq 'MSWin32' ? ';' : ':';
    $config{'shell'} = $^O eq 'MSWin32' ? 'cmd' : 'sh';
    $config{'runner_suffix'} = $^O eq 'MSWin32' ? '.bat' : '';

    my $make = $config{'make'} = $^O eq 'MSWin32' ? 'nmake' : 'make';

    open my $MAKEFILE, '>', 'Makefile'
        or die "Cannot open 'Makefile' for writing: $!";

    my @prefixes = sort map substr($_, 0, 1), keys %backends;

    print $MAKEFILE "\n# Makefile code generated by Configure.pl:\n";

    my $launcher = substr($default_backend, 0, 1) . '-runner-default';
    print $MAKEFILE "all: ", join(' ', map("$_-all", @prefixes), $launcher), "\n";
    print $MAKEFILE "install: ", join(' ', map("$_-install", @prefixes), $launcher . '-install'), "\n";
    for my $t (qw/clean test spectest coretest/) {
        print $MAKEFILE "$t: ", join(' ', map "$_-$t", @prefixes), "\n";
    }

    fill_template_file('tools/build/Makefile-common.in', $MAKEFILE, %config);

    # determine the version of NQP we want
    my ($nqp_want) = split(' ', slurp('tools/build/NQP_REVISION'));

    $options{'gen-nqp'} ||= '' if exists $options{'gen-parrot'} || exists $options{'gen-moar'};

    my %binaries;
    my %impls = gen_nqp($nqp_want, prefix => $prefix, backends => join(',', sort keys %backends), %options);

    my @errors;
    if ($backends{parrot}) {
        my %nqp_config;
        if ($impls{parrot}{ok}) {
            %nqp_config = %{ $impls{parrot}{config} };
        }
        elsif ($impls{parrot}{config}) {
            push @errors, "The nqp-p is too old";
        }
        else {
            push @errors, "Cannot obtain configuration from NQP on parrot";
        }

        my $nqp_have = $nqp_config{'nqp::version'} || '';
        if ($nqp_have && cmp_rev($nqp_have, $nqp_want) < 0) {
            push @errors, "NQP revision $nqp_want required (currently $nqp_have).";
        }

        if (!@errors) {
            push @errors, verify_install([ @NQP::Configure::required_parrot_files,
                                        @NQP::Configure::required_nqp_files ],
                                        %config, %nqp_config);
            push @errors,
            "(Perhaps you need to 'make install', 'make install-dev',",
            "or install the 'devel' package for NQP or Parrot?)"
            if @errors;
        }

        if (@errors && !defined $options{'gen-nqp'}) {
            push @errors,
            "\nTo automatically clone (git) and build a copy of NQP $nqp_want,",
            "try re-running Configure.pl with the '--gen-nqp' or '--gen-parrot'",
            "options.  Or, use '--prefix=' to explicitly",
            "specify the path where the NQP and Parrot executable can be found that are use to build $lang.";
        }

        sorry(@errors) if @errors;

        print "Using $impls{parrot}{bin} (version $nqp_config{'nqp::version'} / Parrot $nqp_config{'parrot::VERSION'}).\n";

        if ($^O eq 'MSWin32' or $^O eq 'cygwin') {
            $config{'dll'} = '$(PARROT_BIN_DIR)/$(PARROT_LIB_SHARED)';
            $config{'dllcopy'} = '$(PARROT_LIB_SHARED)';
            $config{'make_dllcopy'} =
                '$(PARROT_DLL_COPY): $(PARROT_DLL)'."\n\t".'$(CP) $(PARROT_DLL) .';
        }

        my $make = fill_template_text('@make@', %config, %nqp_config);
        fill_template_file('tools/build/Makefile-Parrot.in', $MAKEFILE, %config, %nqp_config);
    }
    if ($backends{jvm}) {
        $config{j_nqp} = $impls{jvm}{bin};
        $config{j_nqp} =~ s{/}{\\}g if $^O eq 'MSWin32';
        my %nqp_config;
        if ( $impls{jvm}{ok} ) {
            %nqp_config = %{ $impls{jvm}{config} };
        }
        elsif ( $impls{jvm}{config} ) {
            push @errors, "nqp-j is too old";
        }
        else {
            push @errors, "Unable to read configuration from NQP on the JVM";
        }
        my $bin = $impls{jvm}{bin};

        if (!@errors && !defined $nqp_config{'jvm::runtime.jars'}) {
            push @errors, "jvm::runtime.jars value not available from $bin --show-config.";
        }

        sorry(@errors) if @errors;
        
        my $java_version = `java -version 2>&1`;
        $java_version    = $java_version =~ /(?<v>[\d\._]+).+\n(?<n>\S+)/
                         ? "$+{'n'} $+{'v'}"
                         : 'no java version info available';

        print "Using $bin (version $nqp_config{'nqp::version'} / $java_version).\n";

        $config{'nqp_prefix'}    = $nqp_config{'jvm::runtime.prefix'};
        $config{'nqp_jars'}      = $nqp_config{'jvm::runtime.jars'};
        $config{'nqp_classpath'} = $nqp_config{'jvm::runtime.classpath'};
        $config{'j_runner'}      = $^O eq 'MSWin32' ? 'perl6-j.bat' : 'perl6-j';


        fill_template_file('tools/build/Makefile-JVM.in', $MAKEFILE, %config);
    }
    if ($backends{moar}) {
        $config{m_nqp} = $impls{moar}{bin};
        $config{m_nqp} =~ s{/}{\\}g if $^O eq 'MSWin32';
        my %nqp_config;
        if ( $impls{moar}{config} ) {
            %nqp_config = %{ $impls{moar}{config} };
        }
        else {
            push @errors, "Unable to read configuration from NQP on MoarVM";
        }
        sorry(@errors) if @errors;

        print "Using $config{m_nqp} (version $nqp_config{'nqp::version'} / MoarVM $nqp_config{'moar::version'}).\n";

        $config{'perl6_ops_dll'} = sprintf($nqp_config{'moar::dll'}, 'perl6_ops_moar');
        
        # Add moar library to link command
        # TODO: Get this from Moar somehow
        $config{'moarimplib'} = $^O eq 'MSWin32' ? "$prefix/bin/moar.dll.lib"
                              : $^O eq 'darwin'  ? "$prefix/lib/libmoar.dylib"
                              : '';

        fill_template_file('tools/build/Makefile-Moar.in', $MAKEFILE, %config, %nqp_config);
    }

    my $l = uc substr($default_backend, 0, 1);
    print $MAKEFILE qq[\nt/*/*.t t/*.t t/*/*/*.t: all\n\t\$(${l}_HARNESS_WITH_FUDGE) --verbosity=1 \$\@\n];

    close $MAKEFILE or die "Cannot write 'Makefile': $!";

    unless ($options{'no-clean'}) {
        no warnings;
        print "Cleaning up ...\n";
        if (open my $CLEAN, '-|', "$make clean") {
            my @slurp = <$CLEAN>;
            close($CLEAN);
        }
    }

    if ($options{'make-install'}) {
        system_or_die($make);
        system_or_die($make, 'install');
        print "\n$lang has been built and installed.\n";
    }
    else {
        print "\nYou can now use '$make' to build $lang.\n";
        print "After that, '$make test' will run some tests and\n";
        print "'$make install' will install $lang.\n";
    }

    exit 0;
}


#  Print some help text.
sub print_help {
    print <<"END";
Configure.pl - $lang Configure

General Options:
    --help             Show this text
    --prefix=dir       Install files in dir; also look for executables there
    --backends=parrot,jvm,moar
                       Which backend(s) to use
    --gen-nqp[=branch]
                       Download and build a copy of NQP
        --gen-moar[=branch]
                       Download and build a copy of MoarVM to use
        --gen-parrot[=branch]
                       Download and build a copy of Parrot
        --parrot-option='--option'
                       Options to pass to Parrot's Configure.pl
        --parrot-make-option='--option'
                       Options to pass to Parrot's make, for example:
                       --parrot-make-option='--jobs=4'
    --makefile-timing  Enable timing of individual makefile commands

Configure.pl also reads options from 'config.default' in the current directory.
END

    return;
}

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 100
# End:
# vim: expandtab shiftwidth=4:
