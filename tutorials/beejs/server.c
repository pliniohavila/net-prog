/*
** server.c -- a stream socket server demo
*/

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/wait.h>
#include <signal.h>

#define PORT "8000"

#define BACKLOG 10  // How many pending connections queue will hold

void    sigchld_handler(int s)
{
  (void)s;

  int saved_errno = errno;

  while (waitpid(-1, NULL, WNOHANG) > 0);

  errno = saved_errno;
}

void    *get_in_addr(struct sockaddr *sa)
{
  if (sa->sa_family == AF_INET) {
    return (&(((struct sockaddr_in*)sa)->sin_addr));
  }

  return (&(((struct sockaddr_in6*)sa)->sin6_addr));
}

int     main(void)
{
  // Listen on sock_fd, new connection on new_fd
  char      s[INET6_ADDRSTRLEN];
  int       sockfd;
  int       new_fd;
  int       yes;
  int       rv;
  socklen_t sin_size;
  struct    addrinfo hints;
  struct    addrinfo *servinfo;
  struct    addrinfo *p;
  struct    sockaddr_storage their_addr; 
  struct    sigaction sa;
  
  yes = 1;

  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_PASSIVE; // listening socket

  // Qual é finalidade de hints e *servinfo
  // Por que passamos &hints e &servinfo
  // int getaddrinfo(char *host, char *service, struct addrinfo *hints, struct addrinfo **result);
  if ((rv = getaddrinfo(NULL, PORT, &hints, &servinfo)) != 0) { // Verificar se realmente preciso deste trecho. p. 114 Stevens
    fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(rv));
    return (1);
  }

  // loop through all the results and bind to the first we can
  for (p = servinfo; p != NULL; p = p->ai_next) {
    if ((sockfd = socket(p->ai_family, p->ai_socktype, p->ai_protocol)) == (-1)) {
      perror("server: socket");
      continue;
    }

    if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(int)) == (-1)) {
      perror("setsockopt");
      exit(1);
    }

    if (bind(sockfd, p->ai_addr, p->ai_addrlen) == (-1)) {
      close(sockfd);
      perror("server: bind");
      continue;
    }

    break;
  }

  freeaddrinfo(servinfo); // all done with this structure

  if (p == NULL) {
    fprintf(stderr, "server: failed to bind\n");
    exit(1);
  }

  if (listen(sockfd, BACKLOG) == (-1)) {
    perror("listen");
    exit(1);
  }

  sa.sa_handler = sigchld_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  if (sigaction(SIGCHLD, &sa, NULL) == (-1)) {
    perror("sigaction");
    exit(1);
  }

  printf("server: waiting for connections in localhost on port %s...\n", PORT);

  while (1) {
    sin_size = sizeof their_addr;
    new_fd = accept(sockfd, (struct sockaddr *)&their_addr, &sin_size);
    // new_fd = accept(sockfd, NULL, NULL); // test from pag 113, Stevens
    // new_fd = accept(sockfd, (struct sockaddr *)&their_addr, &sin_size); 
    if (new_fd == (-1)) {
      perror("accept");
      continue;
    }

    // As letras “p” e “n” significam presentation (apresentação) e numeric (numérico). 
    // inet_ntop faz a conversão inversa, de numérico (addrptr) para apresentação (strptr).
    inet_ntop(their_addr.ss_family, get_in_addr((struct sockaddr *)&their_addr), s, sizeof s);
    printf("server: got connection from: %s - port: %d\n", s,  ntohs(((struct  sockaddr_in*)&their_addr)->sin_port));
    
    
    //
    if (!fork()) { // this is the child process
      close(sockfd); // child doesn't need the listener
      if (send(new_fd, "Hello, world!", 13, 0) == (-1)) {
        perror("send");
      }
      close(new_fd);
      exit(0);
    }
    close(new_fd); // parent doesn't need this
  }

  return (0);
}
