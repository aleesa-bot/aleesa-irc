package Conf;
# loads config

use 5.018;
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);
use English qw ( -no_match_vars );
use Encode qw (encode decode);
use JSON::XS;

use version; our $VERSION = qw (1.0);
use Exporter qw (import);
our @EXPORT_OK = qw (LoadConf);

sub LoadConf {
	my $c = 'data/config.json';
	open my $CH, '<', $c or die "[FATAL] No conf at $c: $OS_ERROR\n";
	my $json;
	my $len = (stat $c) [7];
	my $readlen = read $CH, $json, $len;
	$json = encode 'UTF-8', $json;

	unless ($readlen) {
		close $CH;                                   ## no critic (InputOutput::RequireCheckedSyscalls
		die "[FATAL] Unable to read $c: $OS_ERROR\n";
	}

	close $CH;                                       ## no critic (InputOutput::RequireCheckedSyscalls
	my $j = JSON::XS->new->utf8->relaxed;
	return $j->decode ($json);
}

1;

# vim: set ft=perl noet ai ts=4 sw=4 sts=4:
