#!/usr/bin/perl 

use strict;
use warnings;

use Data::Dumper qw/Dumper/;
use Cwd qw/cwd/;
use File::Temp qw/tempdir/;
use Getopt::Long qw/GetOptions/;
use File::Copy qw/cp mv/;
use File::Basename qw/basename dirname/;
use MIME::Base64 qw/encode_base64/;

my $NOBASE = 0;
my $DRYRUN = 0;
my $SCRIPT = 0;
my $RAISE_ERROR = 0;
my $DOCKER = '';
my $CLONE = '';
my $MIRROR = '';
my @modules = ();

GetOptions(
    nobase => \$NOBASE,
    dryrun => \$DRYRUN,
    script => \$SCRIPT,
    raise => \$RAISE_ERROR,
    'docker:s' => \$DOCKER,
    'clone:s' => \$CLONE,
    'module:s' => \@modules,
    'mirror:s' => \$MIRROR,
);

my %mirrors = (
    iinet => 'http://ftp.ii.net/pub/ubuntu',
    internode => 'http://mirror.internode.on.net/pub/ubuntu/ubuntu',
    ubuntu => 'http://au.archive.ubuntu.com/ubuntu',
);

main(@ARGV);

sub main {
    my ($container) = @_;

    die "No container name specified\n" unless $container;

    my $cwd = cwd();

    my $user = $ENV{SUDO_USER} || $ENV{USER};

    my @base_packages = qw(openssh-server);
    my @packages = ();
    my @ports = ();

    push @packages, @base_packages unless $NOBASE;
    my %config = ();
    my @lxc_args = ();
    $MIRROR ||= 'iinet';
    $MIRROR = $mirrors{$MIRROR} || $MIRROR;

    if (-f "$cwd/containers/$container/modules") {
        open my $fh, '<', "$cwd/containers/$container/modules" or die "Could not open `$cwd/containers/$container/modules': $!\n"; 
        while (my $module = <$fh>) {
            chomp $module;
            push @modules, $module;
        }
        close $fh;
    }

    if (-f "$cwd/base/packages" and not $NOBASE) {
        packages(\@packages, "$cwd/base/packages");
    }

    if (-f "$cwd/base/ports" and not $NOBASE) {
        ports(\@ports, "$cwd/base/ports");
    }

    for my $type (@modules) {
        if (-f "$cwd/modules/$type/packages") {
            packages(\@packages, "$cwd/modules/$type/packages");
        }

        if (-f "$cwd/modules/$type/ports") {
            ports(\@ports, "$cwd/modules/$type/ports");
        }
    } 

    if (-f "$cwd/containers/$container/packages") {
        packages(\@packages, "$cwd/containers/$container/packages");
    }
    if (-f "$cwd/containers/$container/ports") {
        ports(\@ports, "$cwd/containers/$container/ports");
    }

    $config{user} = $user;
    $config{password} = random_string(12);
    $config{mirror} = $MIRROR;
    $config{'auth-key'} = "/home/$user/.ssh/id_rsa.pub";

    config(\%config, "$cwd/base/config") unless $NOBASE;
    for my $type (@modules) {
        if (-f "$cwd/modules/$type/config") {
            config(\%config, "$cwd/modules/$type/config");
        }
    }
    if (-f "$cwd/containers/$container/config") {
        config(\%config, "$cwd/container/$container/config");
    }

    my $devbox = $container =~ /^dev/ ? "1" : "";

    my $rootkey = cat("/home/$user/.ssh/id_rsa.pub");
    chomp $rootkey;

    my $firstboot = undef;

    if ($DOCKER) {
        my $dir = tempdir(CLEANUP => 1);
        $firstboot = File::Temp->new(DIR => $dir);
    } else {
        $firstboot = File::Temp->new();
    }

    print $firstboot "#!/bin/bash\n\n";
    print $firstboot "#firsboot file for $container\n";
    print $firstboot "RELEASE=\$(lsb_release -sc)\n";
    print $firstboot "ARCH=\$(uname -m)\n";
    print $firstboot "DEV=\"$devbox\"\n";
    print $firstboot "USER=\"$user\"\n";
    print $firstboot "SSHKEY=\"$rootkey\"\n";
    print $firstboot "\n";

    if ($RAISE_ERROR) {
	print $firstboot "set -e\nset -u\n\n";
    }

    my @copylist = ();
    if (-f "$cwd/base/copylist") {
        append(\@copylist, "$cwd/base/copylist");
    }
    for my $type (@modules) {
        if (-f "$cwd/modules/$type/copylist") {
            append(\@copylist, "$cwd/modules/$type/copylist");
        }
    } 
    if (-f "$cwd/containers/$container/copylist") {
        append(\@copylist, "$cwd/containers/$container/copylist");
    }

    for my $filename (@copylist) {
        my ($src,$dst) = split ' ', $filename;
        my $basedir = dirname $dst;

        my $mode = sprintf '%04o', (stat $src)[2] & 07777;
        my $base64data = encode_base64(cat($src), '');
        print $firstboot "mkdir -p $basedir\n";
        print $firstboot "echo $base64data|base64 -d>$dst\n";
        print $firstboot "chmod $mode $dst\n";
    }

    if (-f "$cwd/base/firstboot") {
        append($firstboot, "$cwd/base/firstboot");
    }
    
    if (@packages) {
	my %packhash = map {$_ => 1} @packages;
        @packages = sort keys %packhash;

	unless ($DOCKER) {
	    print $firstboot "\n# install packages\nDEBIAN_FRONTEND=noninteractive apt-get -y install " . join(' ', @packages) . "\n";
	}
    }

    for my $type (@modules) {
        if (-f "$cwd/modules/$type/firstboot") {
            append($firstboot, "$cwd/modules/$type/firstboot", 1);
        }
    } 
    if (-f "$cwd/containers/$container/firstboot") {
        append($firstboot, "$cwd/containers/$container/firstboot", 1);
    }

    unless ($DOCKER) {
	print $firstboot "\n\nDEBIAN_FRONTEND=noninteractive apt-get autoremove -y\n";
	print $firstboot "\nDEBIAN_FRONTEND=noninteractive apt-get clean\n";
    }

    close $firstboot;

    my $firstboot_name = $firstboot->filename();

    for my $key (keys %config) {
        push @lxc_args, ("--$key", $config{$key});
    }

    if ($SCRIPT) {
        print cat($firstboot_name); 
        exit 0;
    } elsif ($DOCKER) {
        my $dirname = dirname $firstboot_name;

        my $dockerfile = File::Temp->new(DIR => $dirname);

        $firstboot_name = basename $firstboot_name;

        my ($runscript, @run_args) = split(' ', $DOCKER);

        if (@run_args) {
            $runscript = '[' . join(', ', map {"\"$_\""} ($runscript, @run_args)) . ']';
        }

        my $expose = join("\n", map {"EXPOSE $_"} @ports) || '';

	my $package_list = join(' ', @packages);

        print $dockerfile <<EOF;
FROM       ubuntu:$config{release}
MAINTAINER $user
ADD        $firstboot_name /tmp/installer
RUN        DEBIAN_FRONTEND=noninteractive apt-get update
RUN        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
RUN        DEBIAN_FRONTEND=noninteractive apt-get install -y lsb-release
RUN        DEBIAN_FRONTEND=noninteractive apt-get install -y $package_list
RUN        /bin/bash /tmp/installer
RUN        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
RUN        DEBIAN_FRONTEND=noninteractive apt-get clean
$expose
CMD $runscript
EOF

	if ($DRYRUN) {
	    close $dockerfile;
	    print "Docker file:\n", cat($dockerfile), "\n";
	    print "First boot:\n", cat("$dirname/$firstboot_name"), "\n";
	} else {
	    system qw/sudo docker build --file/, $dockerfile->filename(), '--tag', $container, $dirname;
	}

        exit 0;
    } elsif ($DRYRUN) {
        print "---------------------------\n";
        print "Command:\n sudo lxc-create -t ubuntu -n $container --\n";
        print "---------------------------\n";
        print "Args:\n", join(" ", @lxc_args), "\n";
        print "---------------------------\n";
        print "Mirror:\n$MIRROR\n";
        print "---------------------------\n";
        print "Copy list:\n", join("\n", @copylist), "\n";
        print "---------------------------\n";
        print "First boot:\n", cat($firstboot_name), "\n";
        print "---------------------------\n";
        exit 0;
    } else {
        if ($CLONE) {
            system qw/sudo lxc-clone -s/, $CLONE, $container;
        } else {
            system qw/sudo lxc-create -t ubuntu -n/, $container, '--', @lxc_args;
        }

        system qw/sudo lxc-start -n/, $container;
        system qw/sudo lxc-wait -s RUNNING -n/, $container;
        
        my $ip = get_ip($container);

        chmod 0755, $firstboot_name;
        #system qw/scp/, $firstboot_name, "${user}\@${ip}:$firstboot_name";
        system qw/sudo cp/, $firstboot_name, "/var/lib/lxc/$container/rootfs/$firstboot_name";
        system qw/sudo lxc-attach -n/, $container, qw/--/, $firstboot_name;

        print "Container $container boot on IP $ip\npassword is $config{password}\n";
    }
}

sub get_ip {
    my ($container) = @_;

    my $ip = '';
    for my $i (1 .. 10) {
        $ip = `sudo lxc-info -iH -n $container`;
        chomp $ip;
        last if $ip;
        sleep 1;
    }

    die "Could not determine IP\n" unless $ip;

    return $ip;
}

sub packages {
    my ($packages, $filename) = @_;

    open my $fh, '<', $filename or die "Could not open `$filename': $!\n";
    while (my $package = <$fh>) {
        chomp $package;
        $package =~ s/^\s+//;
        $package =~ s/\s+$//;
        push @$packages, $package;
    }
}

sub ports {
    my ($ports, $filename) = @_;

    open my $fh, '<', $filename or die "Could not open `$filename': $!\n";
    while (my $port = <$fh>) {
        chomp $port;
        $port =~ s/^\s+//;
        $port =~ s/\s+$//;
        push @$ports, $port;
    }
}

sub config {
    my ($config, $filename) = @_;

    open my $fh, '<', $filename or die "Could not open `$filename': $!\n";
    while (my $line = <$fh>) {
        chomp $line;

        if ($line =~ /^\s*(\S+)\s*:\s*(\S+)\s*$/) {
            $config->{$1} = $2;
        }
    }
}

sub cat {
    my ($filename) = @_;

    my $out = '';
    open my $fh, '<', $filename or die "Could not open `$filename': $!\n";
    while (my $line = <$fh>) {
        chomp $line;

        $out .= "$line\n";
    }
    close $fh;

    return $out;
}

sub append {
    my ($out, $filename, $add_filename_comment) = @_;

    open my $in, '<', $filename or die "Could not open `$filename': $!\n";

    if ($add_filename_comment) {
        print $out "\n# $filename\n\n";
    }

    while (my $line = <$in>) {
        chomp $line;
        if (ref $out eq 'ARRAY') {
            push @$out, $line;
        } else {
            print $out $line, "\n";
        }
    }
}

sub random_string {
    my ($count) = @_;

    $count ||= 32;

    my @chars = ('A' .. 'Z', 'a' .. 'z', '0' .. '9');
    
    my $string = '_' x $count;
    $string =~ s/_/@chars[rand(@chars)]/ge;

    return $string;
}

=head1 NAME
build_me_a_container.pl - script to build a container from a collection of templates

=head1 SYNOPSIS

./build_me_a_container.pl [--dryrun] [--nobase] [--script] [--clone=lxc base image] [--mirror=Ubuntu repos url] [--module=build module] <container name>

=head1 DESCRIPTION

Builds a VM
