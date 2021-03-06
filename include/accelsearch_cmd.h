#ifndef __accelsearch_cmd__
#define __accelsearch_cmd__
/*****
  command line parser interface -- generated by clig 
  (http://BSDforge.com/projects/devel/clig/)

  The command line parser `clig':
  (C) 1995-2004 Harald Kirsch (clig@geggus.net)
  (C) 2006-2015 Chris Hutchinson (portmaster@BSDforge.com)
*****/

typedef struct s_Cmdline {
  /***** -gpu: A list of CUDA device ID's, specifying the GPU's to use. If no items are specified all GPU's will be used. Device id's can be found with: accelseach -lsgpu */
  char gpuP;
  int *gpu;
  int gpuC;
  /***** -nbatch: A list of the number of batches of f-∂f planes to process on each CUDA device, Each batch is run in its own thread and allows concurrency. Listed in the same order as -gpu. If only one value is specified it will be used for all GPUs. 0 Means the aplication to determine a good value. */
  char nbatchP;
  int *nbatch;
  int nbatchC;
  /***** -nsteps: A list of the number of f-∂f planes each batch on each CUDA device is to process. Listed in the same order as -gpu. If only one value is specified it will be used for all batches. 0 Means the aplication to determine a good value. */
  char nstepsP;
  int *nsteps;
  int nstepsC;
  /***** -numopt: A list of the number of canidates to process on each CUDA device, Each canidate is run in its own thread and allows concurrency. Listed in the same order as -gpu. If only one value is specified it will be used for all GPUs. 0 Means the aplication to determine a good value. */
  char numoptP;
  int *numopt;
  int numoptC;
  /***** -width: The width of the larges f-∂f plane. Values should be one of 1, 2, 4, 8, 16 or 32 and represent the width in 1000's of the closes power of two. */
  char widthP;
  int width;
  int widthC;
  /***** -lsgpu: List all available CUDA GPU's and exit */
  char lsgpuP;
  /***** -cpu: Do a CPU search */
  char cpuP;
  /***** -ncpus: Number of processors to use with OpenMP */
  char ncpusP;
  int ncpus;
  int ncpusC;
  /***** -lobin: The first Fourier frequency in the data file */
  char lobinP;
  int lobin;
  int lobinC;
  /***** -numharm: The number of harmonics to sum (power-of-two) */
  char numharmP;
  int numharm;
  int numharmC;
  /***** -zmax: The max (+ and -) Fourier freq deriv to search */
  char zmaxP;
  int zmax;
  int zmaxC;
  /***** -sigma: Cutoff sigma for choosing candidates */
  char sigmaP;
  float sigma;
  int sigmaC;
  /***** -rlo: The lowest Fourier frequency (of the highest harmonic!) to search */
  char rloP;
  double rlo;
  int rloC;
  /***** -rhi: The highest Fourier frequency (of the highest harmonic!) to search */
  char rhiP;
  double rhi;
  int rhiC;
  /***** -flo: The lowest frequency (Hz) (of the highest harmonic!) to search */
  char floP;
  double flo;
  int floC;
  /***** -fhi: The highest frequency (Hz) (of the highest harmonic!) to search */
  char fhiP;
  double fhi;
  int fhiC;
  /***** -inmem: Compute full f-fdot plane in memory.  Very fast, but only for short time series. */
  char inmemP;
  /***** -photon: Data is poissonian so use freq 0 as power normalization */
  char photonP;
  /***** -median: Use block-median power normalization (default) */
  char medianP;
  /***** -locpow: Use double-tophat local-power normalization (not usually recommended) */
  char locpowP;
  /***** -zaplist: A file of freqs+widths to zap from the FFT (only if the input file is a *.[s]dat file) */
  char zaplistP;
  char* zaplist;
  int zaplistC;
  /***** -baryv: The radial velocity component (v/c) towards the target during the obs */
  char baryvP;
  double baryv;
  int baryvC;
  /***** -otheropt: Use the alternative optimization (for testing/debugging) */
  char otheroptP;
  /***** -noharmpolish: Do not use 'harmpolish' by default */
  char noharmpolishP;
  /***** -noharmremove: Do not remove harmonically related candidates (never removed for numharm = 1) */
  char noharmremoveP;
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

