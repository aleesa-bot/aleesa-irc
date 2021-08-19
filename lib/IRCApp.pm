package IRCApp;

# общие модули - синтаксис, кодировки итд
use 5.018;
use strict;
use warnings;
use utf8;
use open qw (:std :utf8);

# модули для работы приложения
use Date::Format::ISO8601 qw (gmtime_to_iso8601_datetime);
use Log::Any qw ($log);
use Mojo::Redis;
use Mojo::IOLoop;
use Mojo::IRC;
use Data::Dumper;

use Conf qw (LoadConf);

use version; our $VERSION = qw (1.0);
use Exporter qw (import);
our @EXPORT_OK = qw (RunIRCApp);

my $c = LoadConf ();
my $identified = 0;

# основной парсер
my $parse_redis_message = sub {
	my $self = shift;
	my $m = shift;
	my $answer = $m;
	my $send_to = $answer->{from};

	$self->json ($send_to)->notify (
		$send_to => {
			from    => $answer->{from},
			userid  => $answer->{userid},
			chatid  => $answer->{chatid},
			plugin  => $answer->{plugin},
			message => $answer->{message}
		}
	);

	return;
};

my $on_irc_privmsg = sub {
	my $self = shift;
	$log->warn(Dumper(\@_));
	return;
};

my $on_ctcp_source = sub {
	my $self = shift;
	my $msg = shift;
	my $response_to = (split /!/, $msg->{prefix}, 2)[0];
	$self->write (NOTICE => $response_to => $self->ctcp (SOURCE => 'https://github.com/aleesa-bot/aleesa-irc'));
	return;
};

my $on_ctcp_finger = sub {
	my $self = shift;
	my $msg = shift;
	my $response_to = (split /!/, $msg->{prefix}, 2)[0];
	$self->write (NOTICE => $response_to => $self->ctcp (FINGER => $c->{nick}));
	return;
};

my $on_ctcp_ping = sub {
	my $self = shift;
	my $msg = shift;
	my $response_to = (split /!/, $msg->{prefix}, 2)[0];
	$self->write (NOTICE => $response_to => $self->ctcp (PING => $msg->{params}->[1]));
	return;
};

my $on_ctcp_time = sub {
	my $self = shift;
	my $msg = shift;
	my $response_to = (split /!/, $msg->{prefix}, 2)[0];
	$self->write (NOTICE => $response_to => $self->ctcp (TIME => gmtime_to_iso8601_datetime (time ())));
	return;
};

my $on_ctcp_clientinfo = sub {
	my $self = shift;
	my $msg = shift;
	my $response_to = (split /!/, $msg->{prefix}, 2)[0];
	$self->write (NOTICE => $response_to => $self->ctcp (CLIENTINFO => 'ACTION CLIENTINFO FINGER PING SOURCE TIME USERINFO VERSION'));
	return;
};

my $on_irc_end_of_motd = sub {
	my $self = shift;
	$log->warn(Dumper(\@_));

	# Идентифицируемся в NickServ, если надо
	if (defined ($c->{identify}) && $c->{identify} ne '') {
		# TODO: invent heuristics to detect different login|identify commands depending on particular irc net or
		#       known ircd detected during login procedure
		# Эта команда используется на фриноде (мир праху её) и libera.chat
		$self->write ( qw (PRIVMSG NickServ IDENTIFY $c->{nick} $c->{identify}), \&_on_nickserv_identify);

		until ($identified) { ## no critic (ControlStructures::ProhibitUntilBlocks)
			sleep 1;
		}
	}

	# А теперь заходим на все интересующие нас каналы
	foreach my $chan (@{$c->{channels}}) {
		$self->write ( ('JOIN', $chan), \&_on_join_channel);
	}
	return;
};

sub _on_nickserv_identify {
	my $self = shift;
	my $error = shift;

	if ($error) {
		$log->error ("NickServ identify failed: $error");
		exit 1;
	} else {
		$log->info ('Identified with Nickserv');
		$identified = 1;
	}

	return;
}

sub _on_join_channel {
	my $self = shift;
	my $error = shift;

	if ($error) {
		$log->error ("Unable to join: $error");
	} else {
		$log->info ('Joined');
	}

	return;
}

# зовётся в момент "после коннекта"
sub _on_connect {
	my $self = shift;
	my $error = shift;

	if ($error) {
		$log->error ("Unable to connect: $error");
		exit 1;
	} else {
		$log->info ('Connected.');
	}

	return;
}

sub _on_disconnect {
	my $self = shift;
	my $error = shift;

	if ($error) {
		$log->error ("Unable to Disconnect: $error");
	} else {
		$log->info ('Disconnected.');
	}

	return;
}


# main loop, он же event loop
sub RunIRCApp {
	my $redis = Mojo::Redis->new (
		sprintf 'redis://%s:%s/1', $c->{server}, $c->{port}
	);

	my $pubsub = $redis->pubsub;
	my $sub;

	$pubsub->listen (
		# Вот такая ебическая конструкция для авто-подписывания на все новые каналы.
		# Странное ограничение, при котором на шаблон каналов можно подписаться только, подписавшись на каждый из
		# каналов. То есть подписка создаётся по запросу. В AnyEvent::Redis подписаться можно сразу на * :(
		# Но конкретно в моём случае этот момент неважен, т.к. подразумевается, что каналы будут добавляться, но не 
		# будут убавляться.
		'webapp:*' => sub {
			my ($ps, $channel) = @_ ;

			unless (defined $sub->{$channel}) {
				$log->info ("Subscribing to $channel");

				$sub->{$channel} = $ps->json ($channel)->listen (
					$channel => sub { return $parse_redis_message->(@_); }
				);
			}
		}
	);

	my $irc = Mojo::IRC->new (
		nick => $c->{nick},
		user => $c->{nick},
		server => sprintf '%s:%s', $c->{server}, $c->{port},
	);

	# Нахуй эту вашу проверку подлинности, нам работать надо, а не шашечки.
	if ($c->{ssl}) {
		$irc->tls({ 'insecure' => 1 });
	}

	# включим обработку ctcp-событий
	$irc->parser(Parse::IRC->new(ctcp => 1));

	# добавим коллбэк на момент "после подключения"
	$irc->connect(\&_on_connect);

	# когда приходит это событие, сервер нас поприветствовал и мы можем уже пробовать идентифицироваться у nickserv
	# (если надо) и джойниться к каналам.
	$irc->on ( irc_rpl_endofmotd => sub { return $on_irc_end_of_motd->(@_); } );

	# этот коллбэк будет зваться по мере бесед, сюда попадают все фразы и ctcp
	$irc->on ( irc_privmsg => sub { return $on_irc_privmsg->(@_); } );

	# эти коллбэки будет зваться когда приходят ctcp запросы.
	$irc->on ( ctcp_source => sub { return $on_ctcp_source->(@_); } );
	$irc->on ( ctcp_finger => sub { return $on_ctcp_finger->(@_); } );
	$irc->on ( ctcp_userinfo => sub { return $on_ctcp_finger->(@_); } );
	$irc->on ( ctcp_ping => sub { return $on_ctcp_ping->(@_); } );
	$irc->on ( ctcp_time => sub { return $on_ctcp_time->(@_); } );
	$irc->on ( ctcp_clientinfo => sub { return $on_ctcp_clientinfo->(@_); } );

	# зарегистрируем дефолтные коллбэки на всё, что не закастомизировано
	$irc->register_default_event_handlers;

	do { Mojo::IOLoop->start } until Mojo::IOLoop->is_running;
	return;
}

1;

# vim: set ft=perl noet ai ts=4 sw=4 sts=4:
