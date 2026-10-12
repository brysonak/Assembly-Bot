bits 64
default rel

MSG_CAP     equ 4 * 1024 * 1024
DISCARD_CAP equ 64 * 1024
TOKEN_CAP   equ 256

STD_OUTPUT_HANDLE                    equ -11
WAIT_TIMEOUT                         equ 0x102
WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY  equ 4
WINHTTP_FLAG_SECURE                  equ 0x00800000
WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET equ 114
WINHTTP_QUERY_STATUS_CODE_NUMBER     equ 19 | 0x20000000
WS_BINARY_FRAGMENT                   equ 1
WS_UTF8_MESSAGE                      equ 2
WS_UTF8_FRAGMENT                     equ 3
WS_CLOSE                             equ 4

extern ExitProcess, GetStdHandle, WriteFile, SetConsoleOutputCP, GetEnvironmentVariableA
extern GetLastError, GetTickCount64, Sleep, CreateThread, CreateEventA, SetEvent, ResetEvent
extern WaitForSingleObject, CloseHandle, AcquireSRWLockExclusive, ReleaseSRWLockExclusive
extern WinHttpOpen, WinHttpConnect, WinHttpOpenRequest, WinHttpSetOption, WinHttpSendRequest
extern WinHttpReceiveResponse, WinHttpQueryHeaders, WinHttpReadData, WinHttpCloseHandle
extern WinHttpWebSocketCompleteUpgrade, WinHttpWebSocketSend, WinHttpWebSocketReceive
extern WinHttpWebSocketQueryCloseStatus

global main

%macro LOGN 1+
    section .rdata
%%s: db %1
%%e:
    section .text
    lea rcx, [rel %%s]
    mov edx, %%e - %%s
    call print
%endmacro

%macro LOG 1+
    LOGN %1, 13, 10
%endmacro

; expects the error code in eax
%macro LOGCODE 1
    section .rdata
%%s: db %1
%%e:
    section .text
    mov ecx, eax
    lea rdx, [rel %%s]
    mov r8d, %%e - %%s
    call log_code
%endmacro

%macro FIND 3
    section .rdata
%%k: db %3
%%e:
    section .text
    mov rcx, %1
    mov rdx, %2
    lea r8, [rel %%k]
    mov r9d, %%e - %%k
    call json_find
%endmacro

%macro MATCH 3
    section .rdata
%%k: db %3
%%e:
    section .text
    mov rcx, %1
    mov rdx, %2
    lea r8, [rel %%k]
    mov r9d, %%e - %%k
    call match
%endmacro

section .rdata
w_agent         dw __utf16__('AssemblyBot/1.0'), 0
w_gw_host       dw __utf16__('gateway.discord.gg'), 0
w_gw_path       dw __utf16__('/?v=10&encoding=json'), 0
w_api_host      dw __utf16__('discord.com'), 0
w_get           dw __utf16__('GET'), 0
w_post          dw __utf16__('POST'), 0
w_auth_pre      dw __utf16__('Authorization: Bot ')
w_auth_pre_len  equ $ - w_auth_pre
w_auth_post     dw 13, 10, __utf16__('Content-Type: application/json'), 13, 10, 0
w_auth_post_len equ $ - w_auth_post
w_path_pre      dw __utf16__('/api/v10/channels/')
w_path_pre_len  equ $ - w_path_pre
w_path_post     dw __utf16__('/messages'), 0
w_path_post_len equ $ - w_path_post

token_var         db 'TOKEN', 0
identify_pre      db '{"op":2,"d":{"token":"'
identify_pre_len  equ $ - identify_pre
; GUILDS | GUILD_MESSAGES | DIRECT_MESSAGES | MESSAGE_CONTENT
identify_post     db '","intents":37377,"properties":{"os":"windows","browser":"assembly-bot","device":"assembly-bot"}}}'
identify_post_len equ $ - identify_post
hb_pre            db '{"op":1,"d":'
hb_pre_len        equ $ - hb_pre
s_null            db 'null'
crlf              db 13, 10

ping_pre        db '{"content":"Pong!'
ping_pre_len    equ $ - ping_pre
ping_mid        db ' Gateway latency: '
ping_mid_len    equ $ - ping_mid
ping_ms         db ' ms'
ping_ms_len     equ $ - ping_ms
json_end        db '"}'
hello_body      db '{"content":"Hello from x86-64 assembly!"}'
hello_body_len  equ $ - hello_body

name_ping       db '"!ping"'
name_ping_len   equ $ - name_ping
name_hello      db '"!hello"'
name_hello_len  equ $ - name_hello

align 8
; name, name length, handler(rcx = out) -> rax = end of JSON body
commands:
    dq name_ping,  name_ping_len,  cmd_ping
    dq name_hello, name_hello_len, cmd_hello
    dq 0

section .bss
alignb 8
h_out           resq 1
h_session       resq 1
h_api           resq 1
h_ws            resq 1
h_hb_stop       resq 1
h_hb_thread     resq 1
hb_interval     resq 1
hb_sent_at      resq 1
hb_acked        resq 1
latency_p1      resq 1 ; latency + 1, 0 = unknown
seq_p1          resq 1 ; last sequence + 1, 0 = null
send_lock       resq 1 ; SRWLOCK: main and heartbeat threads both send on h_ws
token_len       resq 1
identify_len    resq 1
token           resb TOKEN_CAP
identify        resb 512
w_auth          resb 1024
w_path          resb 256
body            resb 512
reason          resb 128
resp            resb 1024
discard         resb DISCARD_CAP
msg             resb MSG_CAP

section .text

main:
    sub rsp, 40
    call init
    test eax, eax
    jz .fail
.session:
    call gateway_session
    test eax, eax
    jnz .fail
    LOG "Reconnecting in 5 seconds..."
    mov ecx, 5000
    call Sleep
    jmp .session
.fail:
    mov ecx, 1
    call ExitProcess

init:
    sub rsp, 56
    mov ecx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov [h_out], rax
    mov ecx, 65001
    call SetConsoleOutputCP

    lea rcx, [token_var]
    lea rdx, [token]
    mov r8d, TOKEN_CAP
    call GetEnvironmentVariableA
    test eax, eax
    jz .no_token
    cmp eax, TOKEN_CAP
    jae .no_token
    mov [token_len], rax

    lea rcx, [identify]
    lea rdx, [identify_pre]
    mov r8d, identify_pre_len
    call cpy
    mov rcx, rax
    lea rdx, [token]
    mov r8, [token_len]
    call cpy
    mov rcx, rax
    lea rdx, [identify_post]
    mov r8d, identify_post_len
    call cpy
    lea rcx, [identify]
    sub rax, rcx
    mov [identify_len], rax

    lea rcx, [w_auth]
    lea rdx, [w_auth_pre]
    mov r8d, w_auth_pre_len
    call cpy
    mov rcx, rax
    lea rdx, [token]
    mov r8, [token_len]
    call widen
    mov rcx, rax
    lea rdx, [w_auth_post]
    mov r8d, w_auth_post_len
    call cpy

    lea rcx, [w_agent]
    mov edx, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 0
    call WinHttpOpen
    test rax, rax
    jz .winhttp_fail
    mov [h_session], rax

    mov rcx, rax
    lea rdx, [w_api_host]
    mov r8d, 443
    xor r9d, r9d
    call WinHttpConnect
    test rax, rax
    jz .winhttp_fail
    mov [h_api], rax

    xor ecx, ecx
    mov edx, 1
    xor r8d, r8d
    xor r9d, r9d
    call CreateEventA
    mov [h_hb_stop], rax
    mov eax, 1
    jmp .ret
.no_token:
    LOG "set the token, idiot"
    xor eax, eax
    jmp .ret
.winhttp_fail:
    call GetLastError
    LOGCODE "WinHTTP init failed"
    xor eax, eax
.ret:
    add rsp, 56
    ret

; -> eax = 0 to reconnect, 1 on fatal close
gateway_session:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80 ; [rsp+56] bytes read, [rsp+60] buffer type, [rsp+64] close code, [rsp+68] reason len
    xor r15d, r15d
    LOG "Connecting to gateway..."

    mov rcx, [h_session]
    lea rdx, [w_gw_host]
    mov r8d, 443
    xor r9d, r9d
    call WinHttpConnect
    mov r12, rax
    test rax, rax
    jz .last_error

    mov rcx, r12
    lea rdx, [w_get]
    lea r8, [w_gw_path]
    xor r9d, r9d
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    mov qword [rsp+48], WINHTTP_FLAG_SECURE
    call WinHttpOpenRequest
    mov rbx, rax
    test rax, rax
    jz .last_error

    mov rcx, rbx
    mov edx, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET
    xor r8d, r8d
    xor r9d, r9d
    call WinHttpSetOption
    test eax, eax
    jz .req_error

    mov rcx, rbx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    mov qword [rsp+48], 0
    call WinHttpSendRequest
    test eax, eax
    jz .req_error

    mov rcx, rbx
    xor edx, edx
    call WinHttpReceiveResponse
    test eax, eax
    jz .req_error

    mov rcx, rbx
    xor edx, edx
    call WinHttpWebSocketCompleteUpgrade
    mov r13, rax
    test rax, rax
    jz .req_error
    mov rcx, rbx
    call WinHttpCloseHandle

    mov [h_ws], r13
    mov qword [seq_p1], 0
    mov qword [hb_acked], 1
    mov qword [h_hb_thread], 0

.recv_msg:
    xor r14d, r14d
.recv_frag:
    mov rcx, [h_ws]
    test rcx, rcx
    jz .cleanup
    lea rdx, [msg]
    add rdx, r14
    mov r8d, MSG_CAP
    sub r8, r14
    jnz .room
    lea rdx, [discard] ; oversized message
    mov r8d, DISCARD_CAP
.room:
    mov rdi, rdx
    lea r9, [rsp+56]
    lea rax, [rsp+60]
    mov [rsp+32], rax
    call WinHttpWebSocketReceive
    test eax, eax
    jnz .recv_error
    mov eax, [rsp+60]
    cmp eax, WS_CLOSE
    je .closed
    lea rcx, [discard]
    cmp rdi, rcx
    je .appended
    mov ecx, [rsp+56]
    add r14, rcx
.appended:
    cmp eax, WS_UTF8_FRAGMENT
    je .recv_frag
    cmp eax, WS_BINARY_FRAGMENT
    je .recv_frag
    lea rcx, [msg]
    mov rdx, rcx
    add rdx, r14
    call dispatch
    test eax, eax
    jz .recv_msg
    jmp .cleanup

.recv_error:
    LOGCODE "Gateway receive failed"
    jmp .cleanup

.closed:
    mov word [rsp+64], 0
    mov dword [rsp+68], 0
    mov rcx, r13
    lea rdx, [rsp+64]
    lea r8, [reason]
    mov r9d, 123
    lea rax, [rsp+68]
    mov [rsp+32], rax
    call WinHttpWebSocketQueryCloseStatus
    LOGN "Gateway closed with code "
    movzx ecx, word [rsp+64]
    call print_num
    LOGN ": "
    lea rcx, [reason]
    mov edx, [rsp+68]
    call print
    call print_nl
    movzx eax, word [rsp+64]
    cmp eax, 4004
    je .bad_token
    cmp eax, 4014
    je .bad_intents
    cmp eax, 4010 ; 4010-4013: bad shard / version / intents, retrying won't help
    jb .cleanup
    cmp eax, 4013
    ja .cleanup
    mov r15d, 1
    jmp .cleanup
.bad_token:
    LOG "wrong token dummy"
    mov r15d, 1
    jmp .cleanup
.bad_intents:
    mov r15d, 1
    jmp .cleanup

.req_error:
    call GetLastError
    mov esi, eax
    mov rcx, rbx
    call WinHttpCloseHandle
    mov eax, esi
    jmp .log_fail
.last_error:
    call GetLastError
.log_fail:
    LOGCODE "Gateway connection failed"

.cleanup:
    mov rcx, [h_hb_stop]
    call SetEvent
    mov rcx, [h_hb_thread]
    test rcx, rcx
    jz .no_thread
    mov edx, -1
    call WaitForSingleObject
    mov rcx, [h_hb_thread]
    call CloseHandle
    mov qword [h_hb_thread], 0
.no_thread:
    mov rcx, [h_hb_stop]
    call ResetEvent
    xor eax, eax
    xchg rax, [h_ws]
    test rax, rax
    jz .ws_gone
    mov rcx, rax
    call WinHttpCloseHandle
.ws_gone:
    test r12, r12
    jz .done
    mov rcx, r12
    call WinHttpCloseHandle
.done:
    mov eax, r15d
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = payload, rdx = end -> eax = 1 if the gateway wants us to reconnect
dispatch:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 56
    mov r12, rcx
    mov r13, rdx

    FIND r12, r13, 'op'
    test rax, rax
    jz .continue
    mov rcx, rax
    mov rdx, r13
    call atou
    mov ebx, eax

%ifdef TRACE
    LOGN "[trace] op "
    mov ecx, ebx
    call print_num
    call print_nl
%endif

    FIND r12, r13, 's'
    test rax, rax
    jz .no_seq
    movzx ecx, byte [rax]
    sub ecx, '0'
    cmp ecx, 9
    ja .no_seq
    mov rcx, rax
    mov rdx, r13
    call atou
    inc rax
    mov [seq_p1], rax
.no_seq:
    FIND r12, r13, 'd'
    mov r14, rax

    cmp ebx, 0
    je .op_dispatch
    cmp ebx, 1
    je .op_heartbeat
    cmp ebx, 7
    je .op_reconnect
    cmp ebx, 9
    je .op_invalid
    cmp ebx, 10
    je .op_hello
    cmp ebx, 11
    je .op_ack
    jmp .continue

.op_hello:
    test r14, r14
    jz .continue
    FIND r14, r13, 'heartbeat_interval'
    test rax, rax
    jz .continue
    mov rcx, rax
    mov rdx, r13
    call atou
    test rax, rax
    jz .continue
    mov [hb_interval], rax
    LOGN "Gateway hello, heartbeat every "
    mov rcx, [hb_interval]
    call print_num
    LOG " ms"
    cmp qword [h_hb_thread], 0
    jne .identify
    mov qword [hb_acked], 1
    xor ecx, ecx
    xor edx, edx
    lea r8, [heartbeat_proc]
    xor r9d, r9d
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    call CreateThread
    mov [h_hb_thread], rax
.identify:
    LOG "Identifying..."
    lea rcx, [identify]
    mov rdx, [identify_len]
    call ws_send
    jmp .continue

.op_ack:
    mov qword [hb_acked], 1
    call GetTickCount64
    sub rax, [hb_sent_at]
    inc rax
    mov [latency_p1], rax
    jmp .continue

.op_heartbeat:
    call send_heartbeat
    jmp .continue

.op_reconnect:
    LOG "Gateway requested a reconnect."
    mov eax, 1
    jmp .ret

.op_invalid:
    LOG "Session invalidated."
    mov eax, 1
    jmp .ret

.op_dispatch:
    test r14, r14
    jz .continue
    FIND r12, r13, 't'
    mov rbx, rax
    MATCH rbx, r13, '"MESSAGE_CREATE"'
    test eax, eax
    jz .not_message
    mov rcx, r14
    mov rdx, r13
    call on_message
    jmp .continue
.not_message:
    MATCH rbx, r13, '"READY"'
    test eax, eax
    jz .continue
    FIND r14, r13, 'user'
    test rax, rax
    jz .continue
    FIND rax, r13, 'username'
    test rax, rax
    jz .continue
    mov rbx, rax
    LOGN "Logged in as "
    mov rcx, rbx
    mov rdx, r13
    call print_jstr
    call print_nl

.continue:
    xor eax, eax
.ret:
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rcx = MESSAGE_CREATE "d" object, rdx = end
on_message:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 40
    mov r12, rcx
    mov r13, rdx

    FIND r12, r13, 'author'
    test rax, rax
    jz .check_content
    FIND rax, r13, 'bot'
    MATCH rax, r13, 'true'
    test eax, eax
    jnz .done
.check_content:
    FIND r12, r13, 'content'
    test rax, rax
    jz .done
    mov r14, rax
    lea rbx, [commands]
.next_cmd:
    mov r8, [rbx]
    test r8, r8
    jz .done
    mov rcx, r14
    mov rdx, r13
    mov r9, [rbx+8]
    call match
    test eax, eax
    jnz .found
    add rbx, 24
    jmp .next_cmd

.found:
    FIND r12, r13, 'channel_id'
    test rax, rax
    jz .done
    lea rsi, [rax+1]
    mov rdi, rsi
.chan_end:
    cmp rdi, r13
    jae .done
    cmp byte [rdi], '"'
    je .chan_ok
    inc rdi
    jmp .chan_end
.chan_ok:
    sub rdi, rsi
    cmp rdi, 32
    ja .done

    lea rcx, [body]
    call [rbx+16]
    lea r8, [body]
    sub rax, r8
    mov r9, rax
    mov rcx, rsi
    mov rdx, rdi
    call post_message
    mov r14d, eax

    LOGN "Replied to "
    mov rcx, [rbx]
    mov rdx, rcx
    add rdx, [rbx+8]
    call print_jstr
    LOGN " -> HTTP "
    mov ecx, r14d
    call print_num
    call print_nl
.done:
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = channel id, rdx = length, r8 = JSON body, r9 = length -> eax = HTTP status (0 on failure)
post_message:
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 72 ; [rsp+56] status, [rsp+60] status size, [rsp+64] bytes read
    mov r12, rcx
    mov rbx, rdx
    mov rsi, r8
    mov rdi, r9

    lea rcx, [w_path]
    lea rdx, [w_path_pre]
    mov r8d, w_path_pre_len
    call cpy
    mov rcx, rax
    mov rdx, r12
    mov r8, rbx
    call widen
    mov rcx, rax
    lea rdx, [w_path_post]
    mov r8d, w_path_post_len
    call cpy

    mov rcx, [h_api]
    lea rdx, [w_post]
    lea r8, [w_path]
    xor r9d, r9d
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    mov qword [rsp+48], WINHTTP_FLAG_SECURE
    call WinHttpOpenRequest
    test rax, rax
    jz .open_fail
    mov rbx, rax
    mov dword [rsp+56], 0

    mov rcx, rbx
    lea rdx, [w_auth]
    mov r8d, -1
    mov r9, rsi
    mov [rsp+32], rdi
    mov [rsp+40], rdi
    mov qword [rsp+48], 0
    call WinHttpSendRequest
    test eax, eax
    jz .send_fail
    mov rcx, rbx
    xor edx, edx
    call WinHttpReceiveResponse
    test eax, eax
    jz .send_fail

    mov dword [rsp+60], 4
    mov rcx, rbx
    mov edx, WINHTTP_QUERY_STATUS_CODE_NUMBER
    xor r8d, r8d
    lea r9, [rsp+56]
    lea rax, [rsp+60]
    mov [rsp+32], rax
    mov qword [rsp+40], 0
    call WinHttpQueryHeaders
    cmp dword [rsp+56], 400
    jb .close

    mov dword [rsp+64], 0
    mov rcx, rbx
    lea rdx, [resp]
    mov r8d, 1024
    lea r9, [rsp+64]
    call WinHttpReadData
    lea rcx, [resp]
    mov edx, [rsp+64]
    call print
    call print_nl
    jmp .close

.send_fail:
    call GetLastError
    LOGCODE "Failed to send message"
.close:
    mov rcx, rbx
    call WinHttpCloseHandle
    mov eax, [rsp+56]
    jmp .ret
.open_fail:
    call GetLastError
    LOGCODE "Failed to open REST request"
    xor eax, eax
.ret:
    add rsp, 72
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

cmd_ping:
    push rbx
    sub rsp, 32
    lea rdx, [ping_pre]
    mov r8d, ping_pre_len
    call cpy
    mov rbx, [latency_p1]
    test rbx, rbx
    jz .tail
    mov rcx, rax
    lea rdx, [ping_mid]
    mov r8d, ping_mid_len
    call cpy
    mov rcx, rax
    lea rdx, [rbx-1]
    call utoa
    mov rcx, rax
    lea rdx, [ping_ms]
    mov r8d, ping_ms_len
    call cpy
.tail:
    mov rcx, rax
    lea rdx, [json_end]
    mov r8d, 2
    call cpy
    add rsp, 32
    pop rbx
    ret

cmd_hello:
    lea rdx, [hello_body]
    mov r8d, hello_body_len
    jmp cpy

heartbeat_proc:
    push rbx
    sub rsp, 48
    rdtsc ; first beat at a random point in the interval
    shl rdx, 32
    or rax, rdx
    xor edx, edx
    div qword [hb_interval]
    mov rbx, rdx
.wait:
    mov rcx, [h_hb_stop]
    mov edx, ebx
    call WaitForSingleObject
    cmp eax, WAIT_TIMEOUT
    jne .exit
    xor eax, eax
    xchg rax, [hb_acked]
    test rax, rax
    jz .zombie
    call send_heartbeat
    mov rbx, [hb_interval]
    jmp .wait
.zombie:
    LOG "No heartbeat ACK from gateway, dropping connection."
    xor eax, eax
    xchg rax, [h_ws] ; closing the handle cancels the main thread's blocking receive
    test rax, rax
    jz .exit
    mov rcx, rax
    call WinHttpCloseHandle
.exit:
    xor eax, eax
    add rsp, 48
    pop rbx
    ret

send_heartbeat:
    sub rsp, 104
    call GetTickCount64
    mov [hb_sent_at], rax
    lea rcx, [rsp+32]
    lea rdx, [hb_pre]
    mov r8d, hb_pre_len
    call cpy
    mov rcx, rax
    mov rdx, [seq_p1]
    test rdx, rdx
    jz .null
    dec rdx
    call utoa
    jmp .close
.null:
    lea rdx, [s_null]
    mov r8d, 4
    call cpy
.close:
    mov byte [rax], '}'
    inc rax
    lea rcx, [rsp+32]
    mov rdx, rax
    sub rdx, rcx
    call ws_send
    add rsp, 104
    ret

; rcx = buffer, rdx = length -> eax = WinHTTP error (0 = ok)
ws_send:
    push rbx
    push rsi
    push rdi
    sub rsp, 32
    mov rsi, rcx
    mov rdi, rdx
    lea rcx, [send_lock]
    call AcquireSRWLockExclusive
    mov ebx, 6
    mov rcx, [h_ws]
    test rcx, rcx
    jz .unlock
    mov edx, WS_UTF8_MESSAGE
    mov r8, rsi
    mov r9d, edi
    call WinHttpWebSocketSend
    mov ebx, eax
.unlock:
    lea rcx, [send_lock]
    call ReleaseSRWLockExclusive
    mov eax, ebx
    add rsp, 32
    pop rdi
    pop rsi
    pop rbx
    ret

; rcx = pointer to '{', rdx = end, r8 = key, r9 = key length
json_find:
    push rbx
    push rsi
    xor ebx, ebx
    mov rsi, rcx
.next:
    cmp rsi, rdx
    jae .none
    movzx eax, byte [rsi]
    inc rsi
    cmp al, '"'
    je .string
    cmp al, '{'
    je .open
    cmp al, '['
    je .open
    cmp al, '}'
    je .close
    cmp al, ']'
    je .close
    jmp .next
.open:
    inc ebx
    jmp .next
.close:
    dec ebx
    jz .none
    jmp .next
.string:
    cmp ebx, 1
    jne .skip
    lea rax, [rsi + r9 + 2]
    cmp rax, rdx
    ja .skip
    xor r10d, r10d
.cmp:
    cmp r10, r9
    je .tail
    mov r11b, [rsi + r10]
    cmp r11b, [r8 + r10]
    jne .skip
    inc r10
    jmp .cmp
.tail:
    cmp byte [rsi + r9], '"'
    jne .skip
    cmp byte [rsi + r9 + 1], ':'
    jne .skip
    jmp .ret
.skip:
    cmp rsi, rdx
    jae .none
    movzx eax, byte [rsi]
    inc rsi
    cmp al, '\'
    je .escape
    cmp al, '"'
    jne .skip
    jmp .next
.escape:
    inc rsi
    jmp .skip
.none:
    xor eax, eax
.ret:
    pop rsi
    pop rbx
    ret

; rcx = ptr (may be 0), rdx = end, r8 = literal, r9 = length -> eax = 1 on match
match:
    test rcx, rcx
    jz .no
    lea rax, [rcx + r9]
    cmp rax, rdx
    ja .no
    xor r10d, r10d
.loop:
    cmp r10, r9
    je .yes
    mov al, [rcx + r10]
    cmp al, [r8 + r10]
    jne .no
    inc r10
    jmp .loop
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; rcx = digits, rdx = end -> rax
atou:
    xor eax, eax
.loop:
    cmp rcx, rdx
    jae .done
    movzx r8d, byte [rcx]
    sub r8d, '0'
    cmp r8d, 9
    ja .done
    imul rax, rax, 10
    add rax, r8
    inc rcx
    jmp .loop
.done:
    ret

; rcx = dst, rdx = value -> rax = end
utoa:
    sub rsp, 40
    mov rax, rdx
    lea r9, [rsp+32]
    mov r10d, 10
.div:
    xor edx, edx
    div r10
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz .div
    lea r8, [rsp+32]
.copy:
    mov al, [r9]
    mov [rcx], al
    inc rcx
    inc r9
    cmp r9, r8
    jne .copy
    mov rax, rcx
    add rsp, 40
    ret

; rcx = dst, rdx = src, r8 = length -> rax = dst + length
cpy:
    push rsi
    push rdi
    mov rdi, rcx
    mov rsi, rdx
    mov rcx, r8
    rep movsb
    mov rax, rdi
    pop rdi
    pop rsi
    ret

; rcx = UTF-16 dst, rdx = ASCII src, r8 = length -> rax = end
widen:
    test r8, r8
    jz .done
.loop:
    movzx eax, byte [rdx]
    mov [rcx], ax
    add rcx, 2
    inc rdx
    dec r8
    jnz .loop
.done:
    mov rax, rcx
    ret

; rcx = ptr, rdx = length
print:
    sub rsp, 56
    mov r8, rdx
    mov rdx, rcx
    mov rcx, [h_out]
    lea r9, [rsp+40]
    mov qword [rsp+32], 0
    call WriteFile
    add rsp, 56
    ret

print_nl:
    lea rcx, [crlf]
    mov edx, 2
    jmp print

; rcx = value
print_num:
    sub rsp, 56
    mov rdx, rcx
    lea rcx, [rsp+32]
    call utoa
    lea rcx, [rsp+32]
    mov rdx, rax
    sub rdx, rcx
    call print
    add rsp, 56
    ret

; rcx = pointer to opening quote, rdx = end
print_jstr:
    inc rcx
    mov rax, rcx
.loop:
    cmp rax, rdx
    jae .print
    cmp byte [rax], '"'
    je .print
    inc rax
    jmp .loop
.print:
    mov rdx, rax
    sub rdx, rcx
    jmp print

; ecx = error code, rdx = message, r8 = length
log_code:
    push rbx
    sub rsp, 32
    mov ebx, ecx
    mov rcx, rdx
    mov rdx, r8
    call print
    LOGN " (error "
    mov ecx, ebx
    call print_num
    LOG ")"
    add rsp, 32
    pop rbx
    ret
