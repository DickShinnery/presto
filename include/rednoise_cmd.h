#ifndef __rednoise_cmd__
#define __rednoise_cmd__
/*****
  command line parser interface -- generated by clig 
  (http://BSDforge.com/projects/devel/clig/)

  The command line parser `clig':
  (C) 1995-2004 Harald Kirsch (clig@geggus.net)
  (C) 2006-2015 Chris Hutchinson (portmaster@BSDforge.com)
*****/

typedef struct s_Cmdline {
  /***** -startwidth: The initial windowing size. */
  char startwidthP;
  int startwidth;
  int startwidthC;
  /***** -endwidth: The final windowing size. */
  char endwidthP;
  int endwidth;
  int endwidthC;
  /***** -endfreq: The highest frequency where the windowing increases. */
  char endfreqP;
  double endfreq;
  int endfreqC;
  /***** uninterpreted command line parameters */
  int argc;
  /*@null*/char **argv;
  /***** the whole command line concatenated */
  char *full_cmd_line;
} Cmdline;


extern char *Program;
extern void usage(void);
extern /*@shared*/Cmdline *parseCmdline(int argc, char **argv);

extern void showOptionValues(void);

#endif

