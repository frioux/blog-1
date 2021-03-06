#!/usr/bin/env perl

use strict;
use warnings qw(FATAL);
use feature qw(say);
use experimental qw(signatures);

use Carp::Always;
use Encode qw(encode_utf8);
use File::Basename qw(basename);
use File::Find qw(find);
use File::Slurper qw(read_text write_text);
use JSON qw(decode_json);
use Mojo::URL;
use List::MoreUtils qw(all);
use List::Util qw(max min);

use Carp qw(croak);
use Data::Printer;

our $emitter;
our $emit_meta;
our $post_title;
our $filename;
our %title_map;
our $debug;

sub assert($cond) {
    croak "shit" unless $cond;
}

sub extract_git_data($root, $filename) {
    my $rel_filename = File::Spec->abs2rel(File::Spec->rel2abs($filename), $root);
    # XXX follow renames?
    open my $pipe, '-|', 'git', '-C', $root, 'log', '--date=unix', '--format=%ad', '--', ":/$rel_filename";
    my @timestamps;
    while(<$pipe>) {
        chomp;

        my ( $sec, $min, $hour, $day, $month, $year ) = gmtime($_);

        $month++;
        $year += 1_900;

        push @timestamps, sprintf('%04d%02d%02d%02d%02d%02d000', $year, $month, $day, $hour, $min, $sec);
    }
    $emit_meta->(created  => min(@timestamps));
    $emit_meta->(modified => max(@timestamps));
    close $pipe;
}

sub capture :prototype(&) {
    my ( $action ) = @_;
    my @chunks;
    local $emitter = sub {
        push @chunks, $_[0];
    };
    $action->();
    return join('', @chunks);
}

sub convert_header($payload) {
    my ( $level, $misc, $children ) = @$payload;
    assert(@$payload == 3);
    assert(@$misc == 3);
    assert(@{$misc->[1]} == 0);
    assert(@{$misc->[2]} == 0);

    $emitter->(('!' x $level) . ' ');
    my $header_text = capture {
        convert($_) for @$children;
    };
    if(!defined($post_title)) {
        $post_title = $header_text;
    }
    $emitter->($header_text);
    $emitter->("\n");
}

sub convert_str($text) {
    $emitter->($text);
}

sub convert_space($) {
    $emitter->(' ');
}

sub convert_para($children) {
    convert($_) for @$children;
    $emitter->("\n");
}

sub convert_softbreak($) {
    $emitter->("\n");
}

sub convert_link($payload) {
    my ( $misc, $link_text, $link_url ) = @$payload;

    assert(@$payload == 3);

    assert(@$misc == 3);
    assert($misc->[0] eq '');
    assert(@{$misc->[1]} == 0);
    assert(@{$misc->[2]} == 0);

    assert(@$link_url == 2);
    # XXX dunno if this is ok - check links that are something like /blog/blah-blah
    #assert(scalar($link_url->[0] =~ m{^http[s]?://}));
    assert($link_url->[1] eq '');

    my $accum = capture {
        convert($_) for @$link_text;
    };
    $accum =~ s/\n/ /g;
    my $referent = $link_url->[0];

    if($referent =~ m{^http[s]?://}) {
        my $url = Mojo::URL->new($referent);
        if(($url->host eq 'google.com' || $url->host eq 'www.google.com') && ($url->query->param('btnI') // '') eq 'lucky') {
            my $q = $url->query->param('q');

            if($q =~ /-/) {
                $referent = "https://metacpan.org/release/$q";
            } else {
                $referent = "https://metacpan.org/pod/$q";
            }
        }
    } elsif(keys(%title_map)) {
        # XXX this check for keys(%title_map) sucks
        assert(exists $title_map{$referent});
        $referent = $title_map{$referent};
    }
    if($debug) {
        p $payload;
        say STDERR "[[$accum|$referent]]";
    }
    $emitter->('[[');
    if($accum ne $link_url->[0]) {
        $emitter->($accum);
        $emitter->('|');
    }
    $emitter->($referent);
    $emitter->(']]');
}

sub convert_code($payload) {
    my ( $misc, $text ) = @$payload;
    assert(@$payload == 2);

    assert(@$misc == 3);
    assert($misc->[0] eq '');
    assert(@{$misc->[1]} == 0);
    assert(@{$misc->[2]} == 0);

    $emitter->('`');
    $emitter->($text);
    $emitter->('`');
}

sub convert_image($payload) {
    my ( $one, $two, $path_info ) = @$payload;

    assert(@$payload == 3);

    assert(@$one == 3);
    assert($one->[0] eq '');
    assert(all { $_ eq 'align-center' } @{$one->[1]});
    # XXX this seems to contain things like sizing data - need to handle this
    my %extra_attrs = map { $_->[0] => $_->[1] } @{$one->[2]};
    my $width  = delete $extra_attrs{'width'};
    my $height = delete $extra_attrs{'height'};
    assert(keys(%extra_attrs) == 0);

    assert(@$path_info == 2);
    assert($path_info->[1] eq '');

    my $path = $path_info->[0];

    if($path =~ m{^tag>\s*(.*)}) {
        my @tags = split /\s+/, $1;
        if($filename =~ m{/blog/}) {
            push @tags, '[[Blog Post]]';
        }
        $emit_meta->(tags => join(' ', @tags)); # XXX tiddlywiki space encoding
    } else {
        my $alt = capture {
            convert($_) for @$two;
        };
        my $basename = basename($path);
        my @attrs = (
            qq{source="//hoelz.ro/images/$basename"},
            qq{alt="$alt"},
        );
        push @attrs, qq{width="$width"}   if $width;
        push @attrs, qq{height="$height"} if $height;

        local $" = ' ';
        $emitter->("<\$image @attrs />");
        # XXX do something about alignment?
        #$emitter->("[img[//hoelz.ro/_media/$path]]"); # XXX emit <a> around the img?
        # https://hoelz.ro/_media/blog/robsweeper.png
        # https://hoelz.ro/_detail/blog/robsweeper.png?id=blog%2Fimplementing-minesweeper-in-pharo
    }
}

sub convert_emph($children) {
    $emitter->('//');
    convert($_) for @$children;
    $emitter->('//');
}

sub convert_bulletlist($items) {
    # XXX nested lists?
    for my $item (@$items) {
        $emitter->('* ');
        assert(@$item == 1);
        convert($item->[0]);
        $emitter->("\n");
    }
}

sub convert_plain($children) {
    convert($_) for @$children;
}

sub convert_codeblock($payload) {
    assert(@$payload == 2);
    my ( $meta, $code ) = @$payload;

    assert(@$meta == 3);
    my ( $one, $two, $three ) = @$meta;

    assert($one eq '');
    assert(@$two <= 1);
    assert(@$three == 0);

    my $lang = $two->[0] // '';

    $emitter->('```' . $lang . "\n");
    $emitter->($code);
    $emitter->('```');
}

sub convert_note($children) {
    # XXX is the """ enough?
    $emitter->('<<footnote """');
    convert($_) for @$children;
    # XXX strip newlines?
    $emitter->('""">>');
}

sub convert_strong($children) {
    $emitter->(q{''});
    convert($_) for @$children;
    $emitter->(q{''});
}

sub convert_rawinline($payload) {
    assert($payload->[0] eq 'html');

    $emitter->($payload->[1]);
}

sub convert_orderedlist($payload) {
    assert(@$payload == 2);

    my ( $meta, $items ) = @$payload;

    assert(@$meta == 3);
    assert($meta->[0] == 1);
    assert($meta->[1]{'t'} eq 'DefaultStyle');
    assert($meta->[2]{'t'} eq 'DefaultDelim');

    for my $item (@$items) {
        $emitter->('# ');
        assert(@$item == 1);
        convert($item->[0]);
        $emitter->("\n");
    }
}

sub convert_blockquote($lines) {
    for my $line (@$lines) {
        $emitter->('> ');
        convert($line);
        $emitter->("\n");
    }
}

sub convert_linebreak($payload) {
    # XXX ???
    $emitter->("\n");
}

sub convert($block) {
    my $children = $block->{'c'};
    my $type     = $block->{'t'};

    my $converter = __PACKAGE__->can('convert_' . lc($type));

    die "Can't convert block of type '$type'" unless $converter;

    return $converter->($children);
}

sub build_title_map($root, @documents) {
    my %map;

    local $filename = '';

    for my $doc (@documents) {
        my $process;

        local $emitter   = sub {};
        local $emit_meta = sub {};
        $post_title      = undef;

        for my $child (@{ $doc->{'blocks'} }) {
            convert($child);
        }

        $map{ '/' . File::Spec->abs2rel(File::Spec->rel2abs($doc->{'filename'}), $root) =~ s/[.]txt$//r } = $post_title;
    }

    return %map;
}

my @files;

find(sub {
    return unless -f;
    return unless /[.]txt$/;

    push @files, $File::Find::name;
}, $ARGV[0]);

# remove drafts
@files = grep { !m{drafts/} } @files;

my %seen;

mkdir 'tiddlers/pages';

my @documents;

mkdir '/tmp/page-trees';
for my $filename (@files) {
    my $pipe;

    open $pipe, '-|', 'sha256sum', $filename;
    my $checksum = <$pipe>;
    chomp $checksum;
    $checksum =~ s/\s+.*$//;
    close $pipe;

    my $json;
    if(-e "/tmp/page-trees/$checksum") {
        $json = read_text("/tmp/page-trees/$checksum");
    } else {
        open $pipe, '-|', 'pandoc', '-f', 'dokuwiki', '-t', 'json', $filename;

        $json = do {
            local $/;
            <$pipe>
        };

        close $pipe;

        write_text("/tmp/page-trees/$checksum", $json);
    }

    my $doc = decode_json($json);
    $doc->{'filename'} = $filename;

    push @documents, $doc;
}

%title_map = build_title_map($ARGV[0], @documents);

for my $doc (@documents) {
    $post_title = undef;

    my $blocks      = $doc->{'blocks'};
    local $filename = $doc->{'filename'};

    my %meta;
    my @chunks;

    local $emitter = sub {
        push @chunks, $_[0];
    };

    local $emit_meta = sub {
        $meta{$_[0]} = $_[1];
    };

    # XXX this sucks but whatever
    if($filename =~ m{/blog/}) {
        $emit_meta->(tags => '[[Blog Post]]');
    }

    for my $block (@$blocks) {
        convert($block);
        $emitter->("\n");
    }

    pop @chunks while @chunks && $chunks[-1] =~ /^\s*$/;

    extract_git_data($ARGV[0], $filename);

    die "WTF - no title?" unless defined($post_title);
    $emit_meta->(title => $post_title);

    $post_title =~ s{[:?"/]}{_}g;

    if($post_title !~ /^[-_',.!+a-zA-Z0-9\s]+$/) {
        die "Shit: bad filename: '$post_title'";
    }
    my $full_filename = $post_title . '.tid';
    $full_filename = 'tiddlers/pages/' . $full_filename;

    die "File already accounted for?" if $seen{$full_filename};
    $seen{$full_filename} = 1;

    open my $fh, '>', $full_filename;
    say {$fh} "$_: $meta{$_}" for keys(%meta);
    say {$fh} '';
    print {$fh} encode_utf8($_) for @chunks;
    say {$fh} '';
    close $fh;
}
