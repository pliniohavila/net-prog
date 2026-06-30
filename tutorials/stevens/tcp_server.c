#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/socket.h>     /* For struct sockaddr, socket, accept, listen, bind */
#include <netinet/in.h>  /* For struct sockaddr_in */
#include <arpa/inet.h>   /* For htons, htonl, inet_pton */

#define	SERV_PORT		8000	/* TCP and UDP */
#define	SERV_PORT_STR	"8000"	/* TCP and UDP */
#define	LISTENQ		    1024
#define	MAXLINE		    4096	/* max text line length */
#define	BUFFSIZE	    8192	/* buffer size for reads and writes */
// #define	SA	            struct sockaddr

// https://www.inf.usi.ch/carzaniga/edu/adv-ntw25s/socket_programming.html 

void err_sys(const char* x) 
{ 
    perror(x); 
    exit(1); 
}

void sigchld_handler(int signo) {
    int     saved_errno;
    pid_t   pid;
   
    
    saved_errno = errno;
    (void)signo; // Não prococar alertas de compilação de arg não utilizado

    // waitpid fornece mais controle sobre qual processo esperar e se devemos ou não bloqueá-lo.
    // Primeiro, o argumento pid permite especificar o ID de processo que queremos esperar. 
    // Um Valor de –1 diz para esperar que o primeiro dos nossos filhos termine. (Há outras opções, que lidam com IDs de grupos de processos, mas não precisamos delas neste livro.) 
    // Os argumentos opções permitem especificar opções adicionais. 
    // A opção mais comum é WNOHANG. Essa opção informa o kernel a não bloquear se não houver nenhum filho terminado
    while ((pid = waitpid(-1, NULL, WNOHANG)) > 0) {
        printf("child %d terminated/n", pid);
    }
    
    errno = saved_errno;
}

void	 str_echo(int sockfd) {
    ssize_t     n;
    char        buf[MAXLINE];

    again:
        while ((n = read(sockfd, buf, MAXLINE)) > 0) {
            write(sockfd, buf, n);
        }

        if (n < 0 && errno == EINTR) {
            goto again;
        } else if (n < 0) {
            err_sys("str_echo: read error");
            exit(0);
        }
}

int     main(int argc, char **argv)
{
    int                 listenfd;
    int                 connfd;
    pid_t               childpid;
    socklen_t           clilen;
    struct sockaddr_in  cliaddr;
    struct sockaddr_in  servaddr;
    struct              sigaction sa;

    listenfd = socket(AF_INET, SOCK_STREAM, 0);
    
    memset(&servaddr, 0, sizeof servaddr);
    
    servaddr.sin_family = AF_INET;
    servaddr.sin_addr.s_addr = htonl(INADDR_ANY);
    servaddr.sin_port = htons(SERV_PORT);

    // int yes = 1;
    // setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(int));

    bind(listenfd, (struct sockaddr *) &servaddr, sizeof servaddr);
    listen(listenfd, LISTENQ);
    printf("server: waiting for connections\n");
    fflush(stdout);

    sa.sa_handler = sigchld_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    if (sigaction(SIGCHLD, &sa, NULL) == (-1)) {
        perror("sigaction");
        exit(1);
    }

    while(1) {
        clilen = sizeof(cliaddr);
        connfd = accept(listenfd, (struct sockaddr *) &cliaddr, &clilen);

        if (connfd == (-1)) {
            // if (errno == EINTR) continue; // Interrompido por sinal
            perror("accept");
            continue;
        }
        
        if ((childpid == fork()) == 0) { // child process
            close(listenfd);
            str_echo(connfd);
            exit(0);            
        }

        close(connfd);
    }

    return (0);
}