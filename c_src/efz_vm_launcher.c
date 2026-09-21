/* Linux lifecycle owner, not a sandbox. stdin byte/EOF = kill; stdout JSON.
 * pidfd + PDEATHSIG close parent-death races. waitpid supplies signal evidence. */
#define _GNU_SOURCE
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <unistd.h>
#include <signal.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping=1; }
static long ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000+t.tv_nsec/1000000; }
int main(int argc,char **argv) {
    if(argc<4) return 120;
    pid_t parent=(pid_t)strtol(argv[1],NULL,10);
    signal(SIGUSR1,stop);signal(SIGTERM,stop);signal(SIGINT,stop);signal(SIGPIPE,SIG_IGN);
    if(prctl(PR_SET_PDEATHSIG,SIGUSR1)||prctl(PR_SET_CHILD_SUBREAPER,1)||getppid()!=parent) return 121;
    int pfd=(int)syscall(SYS_pidfd_open,parent,0),logs[2];
    if(pfd<0||getppid()!=parent||pipe2(logs,O_CLOEXEC)) return 122;
    struct rlimit core={0,0};if(setrlimit(RLIMIT_CORE,&core)) return 123;
    pid_t owner=getpid(),child=fork();if(child<0) return 124;
    if(child==0) {
        if(prctl(PR_SET_PDEATHSIG,SIGKILL)||getppid()!=owner||setsid()<0) _exit(125);
        int null=open("/dev/null",O_RDONLY);
        if(null<0||dup2(null,0)<0||dup2(logs[1],1)<0||dup2(logs[1],2)<0) _exit(126);
        close(null);close(logs[0]);close(logs[1]);close(pfd);
        execv(argv[2],argv+2);_exit(127);
    }
    close(logs[1]);fcntl(logs[0],F_SETFL,O_NONBLOCK);
    printf("{\"pid\":%d,\"launcher_pid\":%d}\n",child,getpid());fflush(stdout);
    unsigned char tail[4096];size_t total=0;int status=0,killed=0;
    for(;;) {
        struct pollfd fds[]={{pfd,POLLIN,0},{0,POLLIN|POLLHUP,0},{logs[0],POLLIN,0}};
        int n=poll(fds,3,10);if(n<0&&errno!=EINTR) stopping=1;
        if(fds[0].revents||fds[1].revents) stopping=1;
        if(stopping&&!killed) {kill(-child,SIGKILL);kill(child,SIGKILL);killed=1;}
        unsigned char buf[4096];ssize_t got;
        for(int batch=0;batch<16&&(got=read(logs[0],buf,sizeof(buf)))>0;batch++)
            for(ssize_t j=0;j<got;j++) tail[total++%sizeof(tail)]=buf[j];
        /* Observe without reaping: retain PID ownership until group kill. */
        siginfo_t info={0};
        if(waitid(P_PID,child,&info,WEXITED|WNOHANG|WNOWAIT)<0&&errno!=EINTR) return 128;
        if(info.si_pid==child) {kill(-child,SIGKILL);while(waitpid(child,&status,0)<0&&errno==EINTR) {} break;}
    }
    long until=ms()+2000;int rest,confirmed=0;
    while(ms()<until) {
        pid_t r=waitpid(-1,&rest,WNOHANG);
        if(r<0&&errno==ECHILD) {confirmed=1;break;}
        if(r==0) {
            /* Subreaper owns adopted descendants even if they changed session.
             * Single-threaded: no child can have its PID reused until we reap. */
            char path[80];snprintf(path,sizeof(path),"/proc/self/task/%d/children",getpid());
            FILE *f=fopen(path,"r");int pid;
            if(f) {for(int n=0;n<4096&&fscanf(f,"%d",&pid)==1;n++) kill(pid,SIGKILL);fclose(f);}
            usleep(1000);
        }
    }
    printf("{\"wait_status\":%d,\"exit_code\":%d,\"signal\":%d,\"cleanup_confirmed\":%s,\"launcher_kill\":%s,\"log_bytes\":%zu,\"tail_hex\":\"",
        status,WIFEXITED(status)?WEXITSTATUS(status):-1,WIFSIGNALED(status)?WTERMSIG(status):0,confirmed?"true":"false",killed?"true":"false",total);
    size_t count=total<sizeof(tail)?total:sizeof(tail),start=total-count;
    for(size_t i=0;i<count;i++) printf("%02x",tail[(start+i)%sizeof(tail)]);
    puts("\"}");fflush(stdout);close(logs[0]);close(pfd);return 0;
}
