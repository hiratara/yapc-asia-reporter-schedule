use strict;
use warnings;
use Encode qw(encode_utf8);
use LWP::Simple ();
use Plack::Request;
use Text::Xslate;
use JSON ();
use utf8;

my @reporters = do {
    my $seq = 0;
    map {
        +{id => ++$seq, name => $_};
    } qw(hiratara moznion risou hiroyukim usuihiro muddydixon ytnobody);
};

my %splited_talks = (
    '9b5c4d54-f2c6-11e2-ac33-21c36aeab6a4' => 3,
);

my @schedules = map { +{
    date => $_,
    url => "http://yapcasia.org/2014/talk/schedule?date=2014-08-$_&format=json",
} } 28 .. 30;

my $dir = 'data';
sub save ($) {
    my $r = shift;
    my $assign = $r->param('assign');
    $assign or die $assign;
    my ($talk_id, $reporter_id, undef) = split '/', $assign, 3;
    return unless $talk_id =~ /^[\w\-]+$/;

    if ($reporter_id =~ /^\d+$/) {
        open my $out, '>', "$dir/$talk_id" or die $!;
        print $out $reporter_id;
    } else {
        unlink "$dir/$talk_id" or die;
    }
}

sub load_reporter_id ($) {
    my $talk_id = shift;
    local $/;
    open my $in, '<', "$dir/$talk_id" or return;
    <$in>;
}

sub get_json ($) {
    my $url = shift;
    my $content = LWP::Simple::get($url) or return;
    JSON::from_json($content, {utf8 => 1});
}

sub get_local_json ($) {
    my $date = shift;
    warn "[WARN] using local json file for $date\n";
    local $/;
    open my $in, '<', "$date.json" or die $!;
    JSON::from_json(scalar <$in>, {utf8 => 1});
}

sub _add_time ($$) {
    my ($time, $min) = @_;
    my ($h, $m, $s) = ($time =~ /(\d{2}):(\d{2}):\d{2}/);
    $h = sprintf '%02d', $h + int ($min / 60);
    $m = sprintf '%02d', $m + $min % 60;
    $time =~ s/\d{2}:\d{2}:(\d{2})/$h:$m:$1/g;
    $time;
}

sub _split_talks ($) {
    my $talks = shift;

    @$talks = map {
        my $t = $_;
        if (my $n = $splited_talks{$t->{id}}) {
            my $duration = int ($t->{duration} / $n);
            map {
                my $i = $_;
                my $start_on = _add_time $t->{start_on}, $duration * $i;
                +{
                    %$t,
                    id => "$t->{id}_$i",
                    duration => $duration,
                    start_on => $start_on,
                    ($t->{title} ? (title => "$t->{title}($i)")
                                 : (title_en => "$t->{title_en}($i)")),
                };
            } 0 .. $n - 1;
        } else {
            $t;
        }
    } @$talks;
}

sub time_to_enum ($) {
    my $time_str = shift;
    $time_str =~ /(\d{2}):(\d{2}):/;
    ($1 * 60 + $2) / 10;
}

sub duration_to_enum ($) {
    my $duration = shift;
    $duration / 10;
}

sub put_into_table ($$) {
    my ($table, $talk) = @_;
    my $col = $talk->{venue_id} - 1;
    my $row = time_to_enum $talk->{start_on};
    my $length = duration_to_enum $talk->{duration};
    for (0 .. $length - 1) {
        $table->[$row + $_][$col] = $_ == 0 ? $talk : 1;
    }

    # XXX: Too ugly
    $talk->{span} = $length;
    $talk->{disp_title} = $talk->{title} // $talk->{title_en};
}

sub _cols ($) {
    my $id2name = shift;
    my @cols;
    $cols[$_ - 1] = $id2name->{$_} for keys %$id2name;
    \@cols;
}

sub _rows () {
    [map { my $h = $_; map { sprintf "%02d:%02d", $h, $_ * 10 } 0 .. 5 } 0 .. 23];
}

sub _add_pre_report ($) {
    my $tables = shift;
    # Add pre-report
    unshift @$tables, {
        date => 16,
        cols => _cols {1 => 'gihyo.jp'},
        rows => _rows,
        table => (my $table = []),
    };

    put_into_table $table, {
        id => 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
        venue_id => 1,
        title => "事前レポート",
        'start_on' => '2013-09-16 00:00:00',
        duration => 120,
    };
}

sub _fix_table_info ($) {
    my $info = shift;

    # Drop night and mornings
    while (@{$info->{table}}) {
        last if $info->{table}[0];
        shift @{$info->{table}};
        shift @{$info->{rows}};
    }

    # same sizes
    my $l = @{$info->{cols}};
    for (@{$info->{table}}) {
        push @$_, (undef) x ($l - @$_);
    }
}

sub _walk_on_all_talks (&$) {
    my ($code, $tables) = @_;
    for my $info (@$tables) {
        for my $row (@{$info->{table}}) {
            $code->($_) for grep {$_ && ref $_} @$row;
        }
    }
}

sub _load_assigned ($) {
    my $tables = shift;

    my %result;
    _walk_on_all_talks {
        my $talk = shift;
        $result{$talk->{id}} = load_reporter_id($talk->{id});
    } $tables;

    \%result;
}

sub _summary_reporter ($$) {
    my ($tables, $assigned) = @_;

    my (%summary, $total_duration);
    _walk_on_all_talks {
        my $info = shift;
        my $reporter_id = $assigned->{$info->{id}} or return;

        $summary{$reporter_id}{duration} += $info->{duration};
        $total_duration += $info->{duration};
    } $tables;

    # How much?
    $summary{$_}{ratio} = int (
        100 * $summary{$_}{duration} / $total_duration
    ) for keys %summary;

    \%summary;
}

my $tables = [];
for (@schedules) {
    my $json = get_json $_->{url} // get_local_json $_->{date};
    push @$tables, {
        date => $_->{date},
        cols => _cols $json->{venue_id2name},
        rows => _rows,
        table => (my $table = []),
    };

    for my $talks (@{$json->{talks_by_venue}}) {
        _split_talks $talks;
        put_into_table $table, $_ for @$talks;
    }
}

_add_pre_report $tables;
_fix_table_info $_ for @$tables;

my $tx = Text::Xslate->new;

my $app = sub {
    my $env = shift;
    my $req = Plack::Request->new($env);

    save($req) if $req->param('submit');

    my $assigned = _load_assigned $tables;
    my $body = $tx->render('index.tx', {
        tables => $tables, reporters => \@reporters,
        assigned => $assigned,
        summary_reporter => (_summary_reporter $tables, $assigned),
    });
    [200, ['Content-Type' => 'text/html; charset=utf-8'], [encode_utf8 $body]];
};
