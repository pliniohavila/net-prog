#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>  /* For struct sockaddr, socket, accept, listen, bind */
#include <netinet/in.h>  /* For struct sockaddr_in */
#include <arpa/inet.h>   /* For htons, htonl, inet_pton */

#define	SERV_PORT		8000			/* TCP and UDP */
#define SERV_ADDR       "localhost"

#define	MAXLINE		    4096	/* max text line length */
#define	BUFFSIZE	    8192	/* buffer size for reads and writes */

void    str_cli(FILE *fp, int sockfd)
{
    char    sendline[MAXLINE];
    char    recvline[MAXLINE];

    //  char *fgets(char s[restrict .size], int size, FILE *restrict stream);
    while(fgets(sendline, MAXLINE, fp) != NULL) {
        // ssize_t write(int fd, const void buf[.count], size_t count);
        write(sockfd, sendline, strlen(sendline));
        if (recv(sockfd, recvline, BUFFSIZE, 0) == 0) {
            fprintf(stderr, "tcpclient: server terminated prematurely\n");
            exit(1);
        }
        printf("echo: %s\n", recvline);
    }
}

int     main(int argc, char **argv)
{
    int                 sockfd;
    struct sockaddr_in  servaddr;

    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    memset(&servaddr, 0, sizeof servaddr);
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons(SERV_PORT);

    inet_pton(AF_INET, SERV_ADDR, &servaddr.sin_addr);

    // int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
    connect(sockfd, (struct sockaddr *)&servaddr, sizeof servaddr);

    str_cli(stdin, sockfd);

    return (0);
}