/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2014, VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(websocket,
	  [ http_open_websocket/3,	% +URL, -WebSocket, +Options
	    http_upgrade_to_websocket/3, % :Goal, +Options, +Request
	    ws_send/2,			% +WebSocket, +Message
	    ws_receive/2,		% +WebSocket, -Message
	    ws_close/3,			% +WebSocket, +Code, +Message
					% Low level interface
	    ws_open/3,			% +Stream, -WebSocket, +Options
	    ws_property/2		% +WebSocket, ?Property
	  ]).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_open)).
:- use_module(library(sha)).
:- use_module(library(base64)).
:- use_module(library(option)).
:- use_module(library(lists)).
:- use_module(library(error)).
:- use_module(library(debug)).

:- meta_predicate
	http_upgrade_to_websocket(1, +, +).

:- predicate_options(http_open_websocket/3, 3,
		     [ subprotocols(list(atom)),
		       pass_to(http_open/3, 3)
		     ]).
:- predicate_options(http_upgrade_to_websocket/3, 2,
		     [ guarded(boolean),
		       subprotocols(list(atom))
		     ]).

:- use_foreign_library(foreign(websocket)).

/** <module> WebSocket support

WebSocket is a lightweight message oriented   protocol  on top of TCP/IP
streams. It is typically used as an   _upgrade_ of an HTTP connection to
provide bi-directional communication, but can also  be used in isolation
over arbitrary (Prolog) streams.

The SWI-Prolog interface is based on _streams_ and provides ws_open/3 to
create a _websocket stream_ from any   Prolog stream. Typically, both an
input and output stream are wrapped  and   then  combined  into a single
object using stream_pair/3.

The high-level interface provides http_upgrade_to_websocket/3 to realise
a   websocket   inside   the    HTTP     server    infrastructure    and
http_open_websocket/3 as a layer over http_open/3   to  realise a client
connection. After establishing a connection,  ws_send/2 and ws_receive/2
can be used to send and receive   messages.  The predicate ws_close/2 is
provided to perform the closing  handshake   and  dispose  of the stream
objects.

@see	RFC 6455, http://tools.ietf.org/html/rfc6455
@tbd	Deal with protocol extensions.
*/



		 /*******************************
		 *	   HTTP SUPPORT		*
		 *******************************/

%%	http_open_websocket(+URL, -WebSocket, +Options) is det.
%
%	Establish a client websocket connection.   This  predicate calls
%	http_open/3 with additional headers  to   negotiate  a websocket
%	connection. In addition to the   options processed by http_open,
%	the following options are recognised:
%
%	  - subprotocols(+List)
%	  List of subprotocols that are acceptable. The selected
%	  protocol is available as ws_property(WebSocket,
%	  subprotocol(Protocol).
%
%	The   following   example   exchanges   a   message   with   the
%	html5rocks.websocket.org echo service:
%
%	  ==
%	  ?- URL = 'ws://html5rocks.websocket.org/echo',
%	     http_open_websocket(URL, WS, []),
%	     ws_send(WS, text('Hello World!')),
%	     ws_receive(WS, Reply),
%	     ws_close(WS, "Goodbye").
%	  URL = 'ws://html5rocks.websocket.org/echo',
%	  WS = <stream>(0xe4a440,0xe4a610),
%	  Reply = websocket{data:"Hello World!", opcode:text}.
%	  ==
%
%	@arg WebSocket is a stream pair (see stream_pair/3)

http_open_websocket(URL, WebSocket, Options) :-
	phrase(base64(`___SWI-Prolog___`), Bytes),
	string_codes(Key, Bytes),
	add_subprotocols(Options, Options1),
	http_open(URL, In,
		  [ status_code(Status),
		    output(Out),
		    header(sec_websocket_protocol, Selected),
		    header(sec_websocket_accept, AcceptedKey),
		    connection('Keep-alive, Upgrade'),
		    request_header('Upgrade' = websocket),
		    request_header('Sec-WebSocket-Key' = Key),
		    request_header('Sec-WebSocket-Version' = 13)
		  | Options1
		  ]),
	(   Status == 101,
	    sec_websocket_accept(_{key:Key}, AcceptedKey)
	->  ws_client_options(Selected, WsOptions),
	    ws_open(In,  WsIn,  WsOptions),
	    ws_open(Out, WsOut, WsOptions),
	    stream_pair(WebSocket, WsIn, WsOut)
	;   close(Out),
	    close(In),
	    permission_error(open, websocket, URL)
	).

ws_client_options('',          [mode(client)]) :- !.
ws_client_options(null,        [mode(client)]) :- !.
ws_client_options(Subprotocol, [mode(client), subprotocol(Subprotocol)]).

add_subprotocols(OptionsIn, OptionsOut) :-
	select_option(subprotocols(Subprotocols), OptionsIn, Options1),
	must_be(list(atom), Subprotocols),
	atomic_list_concat(Subprotocols, ', ', Value),
	OptionsOut = [ request_header('Sec-WebSocket-Protocol' = Value)
		     | Options1
		     ].
add_subprotocols(Options, Options).


%%	http_upgrade_to_websocket(:Goal, +Options, +Request)
%
%	Create a websocket connection running call(Goal, WebSocket),
%	where WebSocket is a socket-pair.  Options:
%
%	  * guarded(+Boolean)
%	  If =true= (default), guard the execution of Goal and close
%	  the websocket on both normal and abnormal termination of Goal.
%	  If =false=, Goal itself is responsible for the created
%	  websocket.  This can be used to create a single thread that
%	  manages multiple websockets using I/O multiplexing.
%
%	  * subprotocols(+List)
%	  List of acceptable subprotocols.
%
%	Note that the Request argument is  the last for cooperation with
%	http_handler/3. A simple _echo_ server that   can be accessed at
%	=/ws/= can be implemented as:
%
%         ==
%         :- use_module(library(http/websocket)).
%         :- use_module(library(http/thread_httpd)).
%         :- use_module(library(http/http_dispatch)).
%
%         :- http_handler(root(ws),
%			  http_upgrade_to_websocket(echo, []),
%			  [spawn([])]).
%
%	  echo(WebSocket) :-
%	      ws_receive(WebSocket, Message),
%	      (   Message.opcode == close
%	      ->  true
%	      ;   ws_send(WebSocket, Message),
%	          echo(WebSocket)
%	      ).
%	  ==
%
%	@see http_switch_protocol/2.
%	@throws	switching_protocols(Goal, Options).  The recovery from
%		this exception causes the HTTP infrastructure to call
%		call(Goal, WebSocket).

http_upgrade_to_websocket(Goal, Options, Request) :-
	request_websocket_info(Request, Info),
	debug(websocket(open), 'Websocket request: ~p', [Info]),
	sec_websocket_accept(Info, AcceptKey),
	choose_subprotocol(Info, Options, SubProtocol, ExtraHeaders),
	debug(websocket(open), 'Subprotocol: ~p', [SubProtocol]),
	http_switch_protocol(
	    open_websocket(Goal, SubProtocol, Options),
	    [ header([ upgrade(websocket),
		       connection('Upgrade'),
		       sec_websocket_accept(AcceptKey)
		     | ExtraHeaders
		     ])
	    ]).

choose_subprotocol(Info, Options, SubProtocol, ExtraHeaders) :-
	HdrValue = Info.get(subprotocols),
	option(subprotocols(ServerProtocols), Options),
	split_string(HdrValue, ",", " ", RequestProtocols),
	member(Protocol, RequestProtocols),
	member(SubProtocol, ServerProtocols),
	atom_string(SubProtocol, Protocol), !,
	ExtraHeaders = [ 'Sec-WebSocket-Protocol'(SubProtocol) ].
choose_subprotocol(_, _, null, []).

open_websocket(Goal, SubProtocol, Options, HTTPIn, HTTPOut) :-
	WsOptions = [mode(server), subprotocol(SubProtocol)],
	ws_open(HTTPIn, WsIn, WsOptions),
	ws_open(HTTPOut, WsOut, WsOptions),
	stream_pair(WebSocket, WsIn, WsOut),
	(   option(guarded(true), Options, true)
	->  guard_websocket_server(Goal, WebSocket)
	;   call(Goal, WebSocket)
	).

guard_websocket_server(Goal, WebSocket) :-
	(   catch(call(Goal, WebSocket), E, true)
	->  (   var(E)
	    ->  Msg = bye, Code = 1000
	    ;	message_to_string(E, Msg),
		Code = 1011
	    )
	;   Msg = "goal failed", Code = 1011
	),
	catch(ws_close(WebSocket, Code, Msg), Error,
	      print_message(error, Error)).


request_websocket_info(Request, Info) :-
	option(upgrade(Websocket), Request),
	downcase_atom(Websocket, websocket),
	option(connection(Connection), Request),
	connection_contains_upgrade(Connection),
	option(sec_websocket_key(ClientKey), Request),
	option(sec_websocket_version(Version), Request),
	Info0 = _{key:ClientKey, version:Version},
	add_option(origin,		     Request, origin,       Info0, Info1),
	add_option(sec_websocket_protocol,   Request, subprotocols, Info1, Info2),
	add_option(sec_websocket_extensions, Request, extensions,   Info2, Info).

connection_contains_upgrade(Connection) :-
	split_string(Connection, ",", " ", Tokens),
	member(Token, Tokens),
	string_lower(Token, "upgrade"), !.

add_option(OptionName, Request, Key, Dict0, Dict) :-
	Option =.. [OptionName,Value],
	option(Option, Request), !,
	Dict = Dict0.put(Key,Value).
add_option(_, _, _, Dict, Dict).

%%	sec_websocket_accept(+Info, -AcceptKey) is det.
%
%	Compute the accept key as per 4.2.2., point 5.4

sec_websocket_accept(Info, AcceptKey) :-
	string_concat(Info.key, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", Str),
	sha_hash(Str, Hash, [ algorithm(sha1) ]),
	phrase(base64(Hash), Encoded),
	string_codes(AcceptKey, Encoded).


		 /*******************************
		 *     HIGH LEVEL INTERFACE	*
		 *******************************/

%%	ws_send(+WebSocket, +Message) is det.
%
%	Send a message over a websocket. The following terms are allowed
%	for Message:
%
%	  - text(+Text)
%	    Send a text message.  Text is serialized using write/1.
%	  - binary(+Content)
%	    As text(+Text), but all character codes produced by Content
%	    must be in the range [0..255].  Typically, Content will be
%	    an atom or string holding binary data.
%	  - _{opcode: OpCode}
%	    A dict that minimally contains an =opcode= key.  Other keys
%	    used are:
%	    - data:Term
%	      If this key is present, the message content is the Prolog
%	      serialization of Term based on write/1.
%
%	Note that ws_start_message/3 does not unlock the stream. This is
%	done by ws_send/1. This implies that   multiple  threads can use
%	ws_send/2 and the messages are properly serialized.

ws_send(WsStream, Message) :-
	message_opcode(Message, OpCode),
	setup_call_cleanup(
	    ws_start_message(WsStream, OpCode, 0),
	    write_message_data(WsStream, Message),
	    ws_send(WsStream)).

message_opcode(Message, OpCode) :-
	is_dict(Message), !,
	to_opcode(Message.opcode, OpCode).
message_opcode(Message, OpCode) :-
	functor(Message, Name, _),
	to_opcode(Name, OpCode).

write_message_data(Stream, Message) :-
	is_dict(Message), !,
	(   _{code:Code, data:Data} :< Message
	->  write_message_data(Stream, close(Code, Data))
	;   _{data:Data} :< Message
	->  format(Stream, '~w', Data)
	;   true
	).
write_message_data(Stream, Message) :-
	functor(Message, _, 1), !,
	arg(1, Message, Text),
	format(Stream, '~w', [Text]).
write_message_data(_, Message) :-
	atom(Message), !.
write_message_data(Stream, close(Code, Data)) :- !,
	High is (Code >> 8) /\ 0xff,
	Low  is Code /\ 0xff,
	put_byte(Stream, High),
	put_byte(Stream, Low),
	stream_pair(Stream, _, Out),
	set_stream(Out, encoding(utf8)),
	format(Stream, '~w', [Data]).
write_message_data(_, Message) :-
	type_error(websocket_message, Message).

%%	ws_receive(+WebSocket, -Message:dict) is det.
%
%	Receive the next message  from  WebSocket.   Message  is  a dict
%	containing the following keys:
%
%	  - opcode:OpCode
%	    OpCode of the message.  This is an atom for known opcodes
%	    and an integer for unknown ones.  If the peer closed the
%	    stream, OpCode is bound to =close= and data to the atom
%	    =end_of_file=.
%	  - data:String
%	    The data, represented as a string.  This field is always
%	    present.  String is the empty string if there is no data
%	    in the message.
%	  - rsv:RSV
%	    Present if the WebSocket RSV header is not 0. RSV is an
%	    integer in the range [1..7].
%
%	If =ping= message is received and   WebSocket  is a stream pair,
%	ws_receive/1 replies with a  =pong=  and   waits  for  the  next
%	message.

ws_receive(WsStream, Message) :-
	ws_read_header(WsStream, Code, RSV),
	debug(websocket, 'ws_receive(~p): OpCode=~w, RSV=~w',
	      [WsStream, Code, RSV]),
	(   Code == end_of_file
	->  Message = websocket{opcode:close, data:end_of_file}
	;   (   ws_opcode(OpCode, Code)
	    ->  true
	    ;   OpCode = Code
	    ),
	    read_data(OpCode, WsStream, Data),
	    (	OpCode == ping,
		reply_pong(WsStream, Data.data)
	    ->  ws_receive(WsStream, Message)
	    ;   (   RSV == 0
		->  Message = Data
		;   Message = Data.put(rsv, RSV)
		)
	    )
	),
	debug(websocket, 'ws_receive(~p) --> ~p', [WsStream, Message]).

read_data(close, WsStream, websocket{opcode:close, code:Code, data:Data}) :- !,
	get_byte(WsStream, High),
	(   High == -1
	->  Code = 1000,
	    Data = ""
	;   get_byte(WsStream, Low),
	    Code is High<<8 \/ Low,
	    stream_pair(WsStream, In, _),
	    set_stream(In, encoding(utf8)),
	    read_string(WsStream, _Len, Data)
	).
read_data(OpCode, WsStream, websocket{opcode:OpCode, data:Data}) :-
	read_string(WsStream, _Len, Data).


reply_pong(WebSocket, Data) :-
	stream_pair(WebSocket, _In, Out),
	is_stream(Out),
	ws_send(Out, pong(Data)).


%%	ws_close(+WebSocket:stream_pair, +Code, +Data) is det.
%
%	Close a WebSocket connection by sending a =close= message if
%	this was not already sent and wait for the close reply.
%
%	@error	websocket_error(unexpected_message, Reply) if
%		the other side did not send a close message in reply.

ws_close(WebSocket, Code, Data) :-
	setup_call_cleanup(
	    true,
	    ws_close_(WebSocket, Code, Data),
	    close(WebSocket)).

ws_close_(WebSocket, Code, Data) :-
	stream_pair(WebSocket, In, Out),
	(   (   var(Out)
	    ;	ws_property(Out, status, closed)
	    )
	->  debug(websocket(close),
		  'Output stream of ~p already closed', [WebSocket])
	;   ws_send(WebSocket, close(Code, Data)),
	    close(Out),
	    debug(websocket(close), '~p: closed output', [WebSocket]),
	    (	(   var(In)
		;   ws_property(In, status, closed)
		)
	    ->	debug(websocket(close),
		      'Input stream of ~p already closed', [WebSocket])
	    ;	ws_receive(WebSocket, Reply),
		(   Reply.opcode == close
		->  debug(websocket(close), '~p: close confirmed', [WebSocket])
		;   throw(error(websocket_error(unexpected_message, Reply), _))
		)
	    )
	).


%%	ws_open(+Stream, -WSStream, +Options) is det.
%
%	Turn a raw TCP/IP (or any other  binary stream) into a websocket
%	stream. Stream can be an input stream, output stream or a stream
%	pair. Options includes
%
%	  * mode(+Mode)
%	  One of =server= or =client=.  If =client=, messages are sent
%	  as _masked_.
%
%	  * buffer_size(+Count)
%	  Send partial messages for each Count bytes or when flushing
%	  the output. The default is to buffer the entire message before
%	  it is sent.
%
%	  * close_parent(+Boolean)
%	  If =true= (default), closing WSStream also closes Stream.
%
%	  * subprotocol(+Protocol)
%	  Set the subprotocol property of WsStream.  This value can be
%	  retrieved using ws_property/2.  Protocol is an atom.  See
%	  also the =subprotocols= option of http_open_websocket/3 and
%	  http_upgrade_to_websocket/3.
%
%	A typical sequence to turn a pair of streams into a WebSocket is
%	here:
%
%	  ==
%	      ...,
%	      Options = [mode(server), subprotocol(chat)],
%	      ws_open(Input, WsInput, Options),
%	      ws_open(Output, WsOutput, Options),
%	      stream_pair(WebSocket, WsInput, WsOutput).
%	  ==

%%	ws_start_message(+WSStream, +OpCode) is det.
%%	ws_start_message(+WSStream, +OpCode, +RSV) is det.
%
%	Prepare for sending a new  message.   OpCode  is  one of =text=,
%	=binary=,  =close=,  =ping=  or  =pong=.  RSV  is  reserved  for
%	extensions. After this call, the application usually writes data
%	to  WSStream  and  uses  ws_send/1   to  complete  the  message.
%	Depending on OpCode, the stream  is   switched  to _binary_ (for
%	OpCode is =binary=) or _text_ using   =utf8= encoding (all other
%	OpCode values). For example,  to  a   JSON  message  can be send
%	using:
%
%	  ==
%	  ws_send_json(WSStream, JSON) :-
%	     ws_start_message(WSStream, text),
%	     json_write(WSStream, JSON),
%	     ws_send(WSStream).
%	  ==

%%	ws_send(+WSStream) is det.
%
%	Complete and send the WebSocket message.   If  the OpCode of the
%	message is =close=, close the stream.

%%	ws_read_header(+WSStream, -OpCode, -RSV) is det.
%
%	Read the header of the WebSocket  next message. After this call,
%	WSStream is switched to  the   appropriate  encoding and reading
%	from the stream will  signal  end-of-file   at  the  end  of the
%	message.  Note  that  this  end-of-file  does  *not*  invalidate
%	WSStream.  Reading may perform various tasks on the background:
%
%	  - If the message has _Fin_ is =false=, it will wait for an
%	    additional message.
%	  - If a =ping= is received, it will reply with a =pong= on the
%	    matching output stream.
%	  - If a =pong= is received, it will be ignored.
%	  - If a =close= is received and a partial message is read,
%	    it generates an exception (TBD: which?).  If no partial
%	    message is received, it unified OpCode with =close= and
%	    replies with a =close= message.
%
%	If not all data has been read  for the previous message, it will
%	first read the remainder of the  message. This input is silently
%	discarded. This allows for  trailing   white  space after proper
%	text messages such as JSON, Prolog or XML terms. For example, to
%	read a JSON message, use:
%
%	  ==
%	  ws_read_json(WSStream, JSON) :-
%	      ws_read_header(WSStream, OpCode, RSV),
%	      (	  OpCode == text,
%	          RSV == 0
%	      ->  json_read(WSStream, JSON)
%	      ;	  OpCode == close
%	      ->  JSON = end_of_file
%	      ).
%	  ==

%%	ws_property(+WebSocket, ?Property) is nondet.
%
%	True if Property is  a   property  WebSocket. Defined properties
%	are:
%
%	  * subprotocol(Protocol)
%	  Protocol is the negotiated subprotocol. This is typically set
%	  as a property of the websocket by ws_open/3.

ws_property(WebSocket, Property) :-
	ws_property_(Property, WebSocket).

ws_property_(subprotocol(Protocol), WebSocket) :-
	ws_property(WebSocket, subprotocol, Protocol).

%%	to_opcode(+Spec, -OpCode:int) is det.
%
%	Convert a specification of an opcode into the numeric opcode.

to_opcode(In, Code) :-
	integer(In), !,
	must_be(between(0, 15), In),
	Code = In.
to_opcode(Name, Code) :-
	must_be(atom, Name),
	(   ws_opcode(Name, Code)
	->  true
	;   domain_error(ws_opcode, Name)
	).

%%	ws_opcode(?Name, ?Code)
%
%	Define symbolic names for the WebSocket opcodes.

ws_opcode(continuation,	0).
ws_opcode(text,		1).
ws_opcode(binary,	2).
ws_opcode(close,	8).
ws_opcode(ping,		9).
ws_opcode(pong,		10).


%%	ws_mask(-Mask)
%
%	Produce a good random number of the mask of a client message.

:- public ws_mask/1.

ws_mask(Mask) :-
	Mask is 1+random(1<<32-1).
