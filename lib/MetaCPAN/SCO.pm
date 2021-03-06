package MetaCPAN::SCO;
use strict;
use warnings;

use Carp ();
use Cwd qw(abs_path);
use Data::Dumper qw(Dumper);
use File::Basename qw(dirname);
use HTTP::Tiny;
use JSON qw(from_json to_json);
use LWP::Simple qw(get);
use Path::Tiny qw(path);
use Plack::Builder;
use Plack::Response;
use Plack::Request;
use POSIX qw(strftime);
use Template;
use Time::Local qw(timegm);

our $VERSION = '0.01';

=head1 NAME

SCO - search.cpan.org clone

=cut

my $env;

sub run {
	my $root = root();

	my $app = sub {
		$env = shift;

		my $request = Plack::Request->new($env);
		my $path_info = $request->path_info;
		if ($path_info eq '/') {
			return template('index', {front => 1});
		}
		if ($path_info eq '/feedback') {
			return template('feedback');
		}
		if ($path_info eq '/faq.html') {
			return template('faq');
		}
		if ($path_info eq '/recent') {
			my $recent = recent($request->param('d'));
			return template('recent', { recent => $recent });
		}
		if ($path_info =~ m{^/author/?$}) {
			my $query_string = $request->query_string;
			return template('authors', { letters => ['A' .. 'Z'], authors => [] }) if not $query_string;
			my $lead = substr $query_string, 0, 1;
			my $authors = authors_starting_by(uc $lead);
			if (@$authors) {
				return template('authors', {letters => ['A' .. 'Z'], authors => $authors, selected_letter => uc $lead});
			}
		}

		if ($path_info =~ m{^/~([a-z]+)$}) {
			my $res = Plack::Response->new();
			$res->redirect("$path_info/", 301);
			return $res->finalize;
		}
		if ($path_info =~ m{^/~([a-z]+)/$}) {
			my $pauseid = uc $1;
			my $author = get_author_info($pauseid);
			$author->{cpantester} = substr($pauseid, 0, 1) . '/' . $pauseid;
			my $distros = get_distros_by_pauseid($pauseid);
			return template('author', { author => $author, distributions => $distros });
		}

		if ($path_info =~ m{^/dist/([^/]+)/$}) {
			my $dist_name = $1;
		}

		if ($path_info =~ m{^/~([a-z]+)/([^/]+)/$}) {
			my $data = get_dist_data(uc $1, $2);
			return template('dist', $data);
		}

		if ($path_info eq '/search') {
			return search($request->param('query'), $request->param('mode'));
		}


		my $reply = template('404');
		return [ '404', [ 'Content-Type' => 'text/html' ], $reply->[2], ];
	};

	builder {
		enable 'Plack::Middleware::Static',
			path => qr{^/(favicon.ico|robots.txt)},
			root => "$root/static/";
		$app;
	};
}

sub get_dist_data {
	my ($pauseid, $dist_name_ver) = @_;
			
	# curl 'http://api.metacpan.org/v0/release/AADLER/Games-LogicPuzzle-0.20'
	# curl 'http://api.metacpan.org/v0/release/Games-LogicPuzzle'
	# from https://github.com/CPAN-API/cpan-api/wiki/API-docs
	my $dist;
	my $release;
	my @files;
	eval {
		my $json1 = get 'http://api.metacpan.org/v0/release/' . $pauseid . '/' . $dist_name_ver;
		$dist = from_json $json1;
		my $json2 = get "http://api.metacpan.org/v0/file/_search?q=release:$dist_name_ver&size=1000&fields=release,path,module.name,abstract,module.version,documentation";
		my $data2 = from_json $json2;
		@files = map { $_->{fields} } @{ $data2->{hits}{hits} };
		1;
	} or do {
		my $err = $@  // 'Unknown error';
		warn $err if $err;
	};

	my %SPECIAL = map { $_ => 1 } qw(
		Changes CHANGES LICENSE MANIFEST README
		Makefile.PL Build.PL META.yml META.json
	);

	$_->{name} = delete $_->{'module.name'} for @files;
	$_->{version} = delete $_->{'module.version'} for @files;

	my @modules = sort { $a->{name} cmp $b->{name} } grep { $_->{name} } @files;
	my @documentation = sort { $a->{documentation} cmp $b->{documentation} } grep { $_->{documentation} and not $_->{name} } @files;

	# It seem sco shows META.json if it is available or META.yml if that is available, but not both
	# and prefers to show META.json
	# http://search.cpan.org/~jdb/PPM-Repositories-0.20/
	# http://search.cpan.org/~ironcamel/Business-BalancedPayments-1.0401/
	# I wonder if showing both (when available) can be considered a slight improvement or if we should
	# hide META.yml if there is a META.json already?

	my %special = map { $_->{path} => $_ } grep { $SPECIAL{$_->{path}} } @files;
	if ($special{'META.json'}) {
		delete $special{'META.yml'};
	}

	# TODO: the MANIFEST file gets special treatment here and instead of linking to src/ it is linked without
	# anything and then it is shown with links to the actual files.
	my @special_files = sort { lc $a->{path} cmp lc $b->{path} } values %special;
	$dist->{this_name} = $dist->{name};
	my $author = get_author_info($pauseid);
	return { dist => $dist, author => $author, special_files => \@special_files, modules => \@modules, documentation => \@documentation };
}


sub recent {
	my ($end_ymd) = @_;

	# http://api.metacpan.org/v0/release/_search?q=status:latest&fields=name,status,date&sort=date:desc&size=100

	# 10 most recent releases by OALDERS
	# curl 'http://api.metacpan.org/v0/release/_search?q=status:latest%20AND%20author:OALDERS&fields=name,author,status,date,abstract&sort=date:desc&size=10'

	$end_ymd //= strftime('%Y%m%d', gmtime);
	my @ymd = unpack('A4 A2 A2', $end_ymd);
	my $end_y_m_d = join '-', @ymd;
	my $end_time = timegm(0, 0, 0, $ymd[2], $ymd[1]-1, $ymd[0]);
	my $start_time = $end_time - 7 * 24 * 60 * 60;
	my $start_y_m_d = strftime('%Y-%m-%d', gmtime($start_time));
	my $start_ymd   = strftime('%Y%m%d', gmtime($start_time));
	my $next_ymd;
	if ($end_time < time - 24*60*60) {
		my $next_time = $end_time + 7 * 24 * 60 * 60;
		$next_ymd   = strftime('%Y%m%d', gmtime($next_time));
	}

	my $ua = HTTP::Tiny->new();
	my $query_json = to_json {
		query => {
			match_all => {},
		},
		filter => {
			and => [
				{ term => { status => 'latest', } },
				{
					"range" => {
						"date" => {
							"from" => "${start_y_m_d}T23:59:59",
							"to" => "${end_y_m_d}T23:59:59",
						},
					},
				},
			]
		},
		fields => ["name", "author", "status", "date", "abstract"],
		sort => { date => 'desc' },
		size => 2000,
	};

	my @days;
	eval {
		my $resp = $ua->request(
			'POST',
			'http://api.metacpan.org/v0/release/_search',
			{
				headers => { 'Content-Type' => 'application/json' },
				content => $query_json,
			}
		);
		die if not $resp->{success};
		my $json = $resp->{content};
		my $data = from_json $json;
		my @distros = map { $_->{fields} } @{ $data->{hits}{hits} };
		my %days;
		foreach my $d (@distros) {
			push @{ $days{ substr($d->{date}, 0, 10) } }, $d;
		}
		@days = map { { date => "${_}T12:00:00", dists => $days{$_} } } reverse sort keys %days;
	} or do {
		my $err = $@  // 'Unknown error';
		warn $err if $err;
	};
	my %resp =  ( days => \@days, prev => $start_ymd );
	$resp{next} = $next_ymd;
	return \%resp;
}

sub search {
	my ($query, $mode) = @_;
	
	if ($mode eq 'author') {
		my @authors = [];
		eval {
			my $json = get "http://api.metacpan.org/v0/author/_search?q=author.name:*$query*&size=5000&fields=name";
			my $data = from_json $json;
			@authors =
				sort { $a->{id} cmp $b->{id} }
				map { { id => $_->{_id}, name => $_->{fields}{name} } } @{ $data->{hits}{hits} };
			1;
		} or do {
			my $err = $@  // 'Unknown error';
			warn $err if $err;
		};
		return template('authors', {letters => ['A' .. 'Z'], authors => \@authors, selected_letter => 'X'});
	}

	if ($mode eq 'dist') {
		my @releases = [];
		eval {
			my $json = get "http://api.metacpan.org/v0/release/_search?q=name:*$query*&size=500&fields=date,name,author,abstract,distribution";
			my $data = from_json $json;
			@releases =
				sort { $a->{name} cmp $b->{name} }
				map { $_->{fields} } @{ $data->{hits}{hits} };

			1;
		} or do {
			my $err = $@  // 'Unknown error';
			die $err if $err;
		};
		return template('dists', { dists => \@releases });
	}

	if ($mode eq 'module') {
	}

	# 'all' is the default behaviour:

}

sub get_distros_by_pauseid {
	my ($pause_id) = @_;
	# curl 'http://api.metacpan.org/v0/release/_search?q=author:SZABGAB&size=500'
	# TODO the status:latest filter should be on the query not in the grep

	my @data;
	eval {
		my $json = get 'http://api.metacpan.org/v0/release/_search?q=author:' . $pause_id . '&size=500';
		my $raw = from_json $json;
		@data =
			sort { $a->{name} cmp $b->{name} }
			map { {
			name         => $_->{_source}{name},
			abstract     => $_->{_source}{abstract},
			date         => $_->{_source}{date},
			download_url => $_->{_source}{download_url},
			} }
			grep { $_->{_source}{status} eq 'latest' }
			@{ $raw->{hits}{hits} };
		1;
	} or do {
		my $err = $@  // 'Unknown error';
		warn $err if $err;
	};
	return \@data;
}

sub get_author_info {
	my ($pause_id) = @_;
	my $data;
	eval {
		my $json = get 'http://api.metacpan.org/v0/author/_search?q=author._id:' . $pause_id . '&size=1';
		my $raw = from_json $json;
		$data = $raw->{hits}{hits}[0]{_source};
		1;
	} or do {
		my $err = $@  // 'Unknown error';
		warn $err if $err;
	};
	return $data
}

sub authors_starting_by {
	my ($char) = @_;
	# curl http://api.metacpan.org/v0/author/_search?size=10
	# curl 'http://api.metacpan.org/v0/author/_search?q=author._id:S*&size=10'
	# curl 'http://api.metacpan.org/v0/author/_search?size=10&fields=name'
	# curl 'http://api.metacpan.org/v0/author/_search?q=author._id:S*&size=10&fields=name'
	# or maybe use fetch to download and keep the full list locally:
	# http://api.metacpan.org/v0/author/_search?pretty=true&q=*&size=100000 (from https://github.com/CPAN-API/cpan-api/wiki/API-docs )

	my @authors = [];
	if ($char =~ /[A-Z]/) {
		eval {
			my $json = get "http://api.metacpan.org/v0/author/_search?q=author._id:$char*&size=5000&fields=name";
			my $data = from_json $json;
			@authors =
				sort { $a->{id} cmp $b->{id} }
				map { { id => $_->{_id}, name => $_->{fields}{name} } } @{ $data->{hits}{hits} };
			1;
		} or do {
			my $err = $@  // 'Unknown error';
			warn $err if $err;
		};
	}
	return \@authors;
}


sub template {
	my ( $file, $vars ) = @_;
	$vars //= {};
	Carp::confess 'Need to pass HASH-ref to template()'
		if ref $vars ne 'HASH';

	my $root = root();

	my $ga_file = "$root/config/google_analytics.txt";
	if ( -e $ga_file ) {
		$vars->{google_analytics} = path($ga_file)->slurp_utf8  // '';
	}

	eval {
		$vars->{totals} = from_json path("$root/totals.json")->slurp_utf8;
	};

	my $request = Plack::Request->new($env);
	$vars->{query} = $request->param('query');
	$vars->{mode}  = $request->param('mode');

	my $tt = Template->new(
		INCLUDE_PATH => "$root/tt",
		INTERPOLATE  => 0,
		POST_CHOMP   => 1,
		EVAL_PERL    => 1,
		START_TAG    => '<%',
		END_TAG      => '%>',
		PRE_PROCESS  => 'incl/header.tt',
		POST_PROCESS => 'incl/footer.tt',
	);
	my $out;
	$tt->process( "$file.tt", $vars, \$out )
		|| Carp::confess $tt->error();
	return [ '200', [ 'Content-Type' => 'text/html' ], [$out], ];
}

sub root {
	my $dir = dirname(dirname(dirname( abs_path(__FILE__) )));
	$dir =~ s{blib/?$}{};
	return $dir;
}

1;

