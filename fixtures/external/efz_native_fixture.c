/* Test only. Must never load into the test runner/supervisor BEAM. */
#include <erl_nif.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static ERL_NIF_TERM act(ErlNifEnv *env,int argc,const ERL_NIF_TERM argv[]) {
    (void)argc;ErlNifBinary b;
    if(!enif_inspect_binary(env,argv[0],&b)) return enif_make_badarg(env);
    const char *path=getenv("EFZ_NATIVE_MARKER");
    if(path) {int f=open(path,O_WRONLY|O_APPEND|O_CREAT,0600);if(f>=0){dprintf(f,"%d ",getpid());if(write(f,b.data,b.size)<0||write(f,"\n",1)<0) abort();close(f);}}
    if(b.size==4&&!memcmp(b.data,"SEGV",4)) {signal(SIGSEGV,SIG_DFL);raise(SIGSEGV);}
    if(b.size==4&&!memcmp(b.data,"ABRT",4)) abort();
    if(b.size==7&&!memcmp(b.data,"EXIT139",7)) _exit(139);
    if(b.size==4&&!memcmp(b.data,"HANG",4)) {for(;;) {__asm__ volatile("" ::: "memory");}}
    if(b.size==5&&!memcmp(b.data,"NOISE",5)) {
        char block[4096];memset(block,'X',sizeof(block));
        for(int i=0;i<1024;i++) {if(write(1,block,sizeof(block))<0||write(2,block,sizeof(block))<0) abort();}
    }
    return enif_make_atom(env,"ok");
}
static int load(ErlNifEnv *e,void **p,ERL_NIF_TERM i) {
    (void)e;(void)p;(void)i;
    if(getenv("EFZ_NATIVE_STARTUP_CRASH")) abort();
    return 0;
}
static ErlNifFunc funcs[]={{"act",1,act,0}};
ERL_NIF_INIT(efz_native_fixture,funcs,load,NULL,NULL,NULL)
