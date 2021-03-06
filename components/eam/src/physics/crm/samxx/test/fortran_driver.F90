
program driver
  use crmdims
  use params_kind, only: crm_rknd
  use crm_input_module
  use crm_output_module
  use crm_state_module
  use crm_rad_module
  use accelerate_crm_mod
  use crm_ecpp_output_module
  use dmdf
  use crm_module
#if HAVE_MPI
  use mpi
#endif
  implicit none
  type(crm_input_type)         :: crm_input
  type(crm_output_type)        :: crm_output
  type(crm_state_type)         :: crm_state
  type(crm_rad_type)           :: crm_rad
  type(crm_ecpp_output_type)   :: crm_ecpp_output
  integer          , parameter :: plev   = PLEV
  character(len=64), parameter :: fname_in = 'input.nc'
  real(crm_rknd), allocatable  :: lat0  (:)
  real(crm_rknd), allocatable  :: long0 (:)
  real(crm_rknd), allocatable  :: dt_gl (:)
  integer                      :: icrm, nranks, rank, myTasks_beg, myTasks_end, irank, ncrms
  logical                      :: masterTask
  real(crm_rknd), allocatable :: read_crm_input_zmid       (:,:)
  real(crm_rknd), allocatable :: read_crm_input_zint       (:,:)
  real(crm_rknd), allocatable :: read_crm_input_tl         (:,:)
  real(crm_rknd), allocatable :: read_crm_input_ql         (:,:)
  real(crm_rknd), allocatable :: read_crm_input_qccl       (:,:)
  real(crm_rknd), allocatable :: read_crm_input_qiil       (:,:)
  real(crm_rknd), allocatable :: read_crm_input_pmid       (:,:)
  real(crm_rknd), allocatable :: read_crm_input_pint       (:,:)
  real(crm_rknd), allocatable :: read_crm_input_pdel       (:,:)
  real(crm_rknd), allocatable :: read_crm_input_ul         (:,:)
  real(crm_rknd), allocatable :: read_crm_input_vl         (:,:)
  real(crm_rknd), allocatable :: read_crm_state_u_wind     (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_state_v_wind     (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_state_w_wind     (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_state_temperature(:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_state_qt         (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_state_qp         (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_state_qn         (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_rad_qrad         (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_rad_temperature  (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_rad_qv           (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_rad_qc           (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_rad_qi           (:,:,:,:)
  real(crm_rknd), allocatable :: read_crm_rad_cld          (:,:,:,:)
  real(crm_rknd), allocatable :: crm_clear_rh(:,:)
  integer       , allocatable :: gcolp(:)
  character(len=64) :: fprefix = 'fortran_output'
  integer(8) :: t1, t2, tr
  integer :: ierr

  logical :: use_MMF_VT                    ! flag for MMF variance transport
  integer :: MMF_VT_wn_max                 ! wavenumber cutoff for filtered variance transport
  character(len=7) :: microphysics_scheme = 'sam1mom'

#if HAVE_MPI
  call mpi_init(ierr)
  call mpi_comm_size(mpi_comm_world,nranks,ierr)
  call mpi_comm_rank(mpi_comm_world,rank,ierr)
#else
  nranks = 1
  rank = 0
#endif
  call distr_indices(NCRMS,nranks,rank,myTasks_beg,myTasks_end)
  ncrms = myTasks_end - myTasks_beg + 1
  masterTask = rank == 0

  ! write(*,*) 'Number of tasks:    ', nranks
  ! write(*,*) 'My task:            ', rank
  ! write(*,*) 'My beginning index: ', myTasks_beg
  ! write(*,*) 'My ending index:    ', myTasks_end
  ! write(*,*) 'My ncrms:           ', ncrms

  if (masterTask) then
    write(*,*) "File   : ", trim(fname_in)
    write(*,*) "Samples: ", ncrms
    write(*,*) "crm_nx : ", crm_nx
    write(*,*) "crm_ny : ", crm_ny
    write(*,*) "crm_dx : ", crm_dx
    write(*,*) "crm_dt : ", crm_dt
    write(*,*) "plev   : ", plev 
  endif

  ! Allocate model data
  call crm_state_initialize (crm_state , ncrms, crm_nx, crm_ny, crm_nz, trim(microphysics_scheme))
  call crm_rad_initialize   (crm_rad   , ncrms, crm_nx_rad, crm_ny_rad, crm_nz, trim(microphysics_scheme))
  call crm_input_initialize (crm_input , ncrms, plev, trim(microphysics_scheme))
  call crm_output_initialize(crm_output, ncrms, plev, crm_nx, crm_ny, crm_nz, trim(microphysics_scheme))

  ! These are normally allocated by pbuf, so we have to do it explicitly
  allocate( lat0                 (ncrms) )
  allocate( long0                (ncrms) )
  allocate( dt_gl                (ncrms) )
  allocate( gcolp                (ncrms) )
  allocate( crm_clear_rh         (ncrms,crm_nz) )
  
  ! Allocate transposed arrays because this is the storage format in netcdf
  allocate( read_crm_input_zmid       (plev  ,ncrms))
  allocate( read_crm_input_zint       (plev+1,ncrms))
  allocate( read_crm_input_tl         (plev  ,ncrms))
  allocate( read_crm_input_ql         (plev  ,ncrms))
  allocate( read_crm_input_qccl       (plev  ,ncrms))
  allocate( read_crm_input_qiil       (plev  ,ncrms))
  allocate( read_crm_input_pmid       (plev  ,ncrms))
  allocate( read_crm_input_pint       (plev+1,ncrms))
  allocate( read_crm_input_pdel       (plev  ,ncrms))
  allocate( read_crm_input_ul         (plev  ,ncrms))
  allocate( read_crm_input_vl         (plev  ,ncrms))
  allocate( read_crm_state_u_wind     (crm_nx    ,crm_ny    ,crm_nz,ncrms) )
  allocate( read_crm_state_v_wind     (crm_nx    ,crm_ny    ,crm_nz,ncrms) )
  allocate( read_crm_state_w_wind     (crm_nx    ,crm_ny    ,crm_nz,ncrms) )
  allocate( read_crm_state_temperature(crm_nx    ,crm_ny    ,crm_nz,ncrms) )
  allocate( read_crm_state_qt         (crm_nx    ,crm_ny    ,crm_nz,ncrms) )
  allocate( read_crm_state_qp         (crm_nx    ,crm_ny    ,crm_nz,ncrms) )
  allocate( read_crm_state_qn         (crm_nx    ,crm_ny    ,crm_nz,ncrms) )
  allocate( read_crm_rad_qrad         (crm_nx_rad,crm_ny_rad,crm_nz,ncrms) )
  allocate( read_crm_rad_temperature  (crm_nx_rad,crm_ny_rad,crm_nz,ncrms) )
  allocate( read_crm_rad_qv           (crm_nx_rad,crm_ny_rad,crm_nz,ncrms) )
  allocate( read_crm_rad_qc           (crm_nx_rad,crm_ny_rad,crm_nz,ncrms) )
  allocate( read_crm_rad_qi           (crm_nx_rad,crm_ny_rad,crm_nz,ncrms) )
  allocate( read_crm_rad_cld          (crm_nx_rad,crm_ny_rad,crm_nz,ncrms) )
  
  ! Read in the samples to drive the code
  if (masterTask) then
    write(*,*) 'Reading the data'
  endif
  call dmdf_read( dt_gl                      , fname_in , trim("dt_gl            ") , myTasks_beg , myTasks_end , .true.  , .false. )
  call dmdf_read( lat0                       , fname_in , trim("latitude0        ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( long0                      , fname_in , trim("longitude0       ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_zmid        , fname_in , trim("in_zmid          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_zint        , fname_in , trim("in_zint          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_tl          , fname_in , trim("in_tl            ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_ql          , fname_in , trim("in_ql            ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_qccl        , fname_in , trim("in_qccl          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_qiil        , fname_in , trim("in_qiil          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_pmid        , fname_in , trim("in_pmid          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_pint        , fname_in , trim("in_pint          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_pdel        , fname_in , trim("in_pdel          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_ul          , fname_in , trim("in_ul            ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_input_vl          , fname_in , trim("in_vl            ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_state_u_wind      , fname_in , trim("state_u_wind     ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_state_v_wind      , fname_in , trim("state_v_wind     ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_state_w_wind      , fname_in , trim("state_w_wind     ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_state_temperature , fname_in , trim("state_temperature") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_state_qt          , fname_in , trim("state_qt         ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_state_qp          , fname_in , trim("state_qp         ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_state_qn          , fname_in , trim("state_qn         ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_rad_qrad          , fname_in , trim("rad_qrad         ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_rad_temperature   , fname_in , trim("rad_temperature  ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_rad_qv            , fname_in , trim("rad_qv           ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_rad_qc            , fname_in , trim("rad_qc           ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_rad_qi            , fname_in , trim("rad_qi           ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( read_crm_rad_cld           , fname_in , trim("rad_cld          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%ps               , fname_in , trim("in_ps            ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%phis             , fname_in , trim("in_phis          ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%ocnfrac          , fname_in , trim("in_ocnfrac       ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%tau00            , fname_in , trim("in_tau00         ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%wndls            , fname_in , trim("in_wndls         ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%bflxls           , fname_in , trim("in_bflxls        ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%fluxu00          , fname_in , trim("in_fluxu00       ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%fluxv00          , fname_in , trim("in_fluxv00       ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%fluxt00          , fname_in , trim("in_fluxt00       ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_input%fluxq00          , fname_in , trim("in_fluxq00       ") , myTasks_beg , myTasks_end , .false. , .false. )
  call dmdf_read( crm_output%subcycle_factor   , fname_in , trim("out_subcycle_factor") , myTasks_beg , myTasks_end , .false. , .true.  )

  print *, 'Reading crm_input...'
  do icrm = 1 , ncrms
    crm_input%zmid       (icrm,:)     = read_crm_input_zmid       (:    ,icrm)                       
    crm_input%zint       (icrm,:)     = read_crm_input_zint       (:    ,icrm)                       
    crm_input%tl         (icrm,:)     = read_crm_input_tl         (:    ,icrm)                       
    crm_input%ql         (icrm,:)     = read_crm_input_ql         (:    ,icrm)                       
    crm_input%qccl       (icrm,:)     = read_crm_input_qccl       (:    ,icrm)                       
    crm_input%qiil       (icrm,:)     = read_crm_input_qiil       (:    ,icrm)                       
    crm_input%pmid       (icrm,:)     = read_crm_input_pmid       (:    ,icrm)                       
    crm_input%pint       (icrm,:)     = read_crm_input_pint       (:    ,icrm)                       
    crm_input%pdel       (icrm,:)     = read_crm_input_pdel       (:    ,icrm)                       
    crm_input%ul         (icrm,:)     = read_crm_input_ul         (:    ,icrm)                       
    crm_input%vl         (icrm,:)     = read_crm_input_vl         (:    ,icrm)                       
  enddo
  print *, 'Reading crm_state...'
  do icrm = 1 , ncrms
    crm_state%u_wind     (icrm,:,:,:) = read_crm_state_u_wind     (:,:,:,icrm) 
    crm_state%v_wind     (icrm,:,:,:) = read_crm_state_v_wind     (:,:,:,icrm) 
    crm_state%w_wind     (icrm,:,:,:) = read_crm_state_w_wind     (:,:,:,icrm) 
    crm_state%temperature(icrm,:,:,:) = read_crm_state_temperature(:,:,:,icrm) 
    crm_state%qt         (icrm,:,:,:) = read_crm_state_qt         (:,:,:,icrm) 
    crm_state%qp         (icrm,:,:,:) = read_crm_state_qp         (:,:,:,icrm) 
    crm_state%qn         (icrm,:,:,:) = read_crm_state_qn         (:,:,:,icrm) 
  enddo
  print *, 'Reading crm_rad...'
  do icrm = 1 , ncrms
    crm_rad%qrad         (icrm,:,:,:) = read_crm_rad_qrad         (:,:,:,icrm) 
    crm_rad%temperature  (icrm,:,:,:) = read_crm_rad_temperature  (:,:,:,icrm) 
    crm_rad%qv           (icrm,:,:,:) = read_crm_rad_qv           (:,:,:,icrm) 
    crm_rad%qc           (icrm,:,:,:) = read_crm_rad_qc           (:,:,:,icrm) 
    crm_rad%qi           (icrm,:,:,:) = read_crm_rad_qi           (:,:,:,icrm) 
    crm_rad%cld          (icrm,:,:,:) = read_crm_rad_cld          (:,:,:,icrm) 
  enddo

  if (masterTask) then
    write(*,*) 'Running the CRM'
  endif

  if (masterTask) then
    call system_clock(t1)
  endif

  use_MMF_VT = .false.
  MMF_VT_wn_max = 0

  ! Run the code
  call crm(1 , ncrms, dt_gl(1), plev, crm_input, crm_state, crm_rad, crm_ecpp_output, crm_output, crm_clear_rh, &
           lat0, long0, gcolp, 2, &
           use_MMF_VT, MMF_VT_wn_max, &
           .true., 2.D0, .true.)


#if HAVE_MPI
  call mpi_barrier(mpi_comm_world,ierr)
#endif
  if (masterTask) then
    call system_clock(t2,tr)
    write(*,*) "Elapsed Time: " , real(t2-t1,8) / real(tr,8)
  endif

  if (masterTask) then
    write(*,*) 'Writing output data'
  endif
  ! dmdf_write(dat,rank,fprefix,vname       ,first,last) !For scalar values
  ! dmdf_write(dat,rank,fprefix,vname,dnames,first,last) !For array values

  do irank = 0 , nranks-1
    if (irank == rank) then
      do icrm = 1 , ncrms
        call dmdf_write( crm_state%u_wind         (icrm,:,:,:) , 1 , fprefix , trim('state_u_wind        ') , (/'crm_nx','crm_ny','crm_nz'/)             , .true.  , .false. )
        call dmdf_write( crm_state%v_wind         (icrm,:,:,:) , 1 , fprefix , trim('state_v_wind        ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_state%w_wind         (icrm,:,:,:) , 1 , fprefix , trim('state_w_wind        ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_state%temperature    (icrm,:,:,:) , 1 , fprefix , trim('state_temperature   ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_state%qt             (icrm,:,:,:) , 1 , fprefix , trim('state_qt            ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_state%qp             (icrm,:,:,:) , 1 , fprefix , trim('state_qp            ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_state%qn             (icrm,:,:,:) , 1 , fprefix , trim('state_qn            ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%qcl           (icrm,:,:,:) , 1 , fprefix , trim('output_qcl          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%qci           (icrm,:,:,:) , 1 , fprefix , trim('output_qci          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%qpl           (icrm,:,:,:) , 1 , fprefix , trim('output_qpl          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%qpi           (icrm,:,:,:) , 1 , fprefix , trim('output_qpi          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%tk            (icrm,:,:,:) , 1 , fprefix , trim('output_tk           ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%tkh           (icrm,:,:,:) , 1 , fprefix , trim('output_tkh          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%prec_crm      (icrm,:,:)   , 1 , fprefix , trim('output_prec_crm     ') , (/'crm_nx','crm_ny'/)                      , .false. , .false. )
        call dmdf_write( crm_output%wvar          (icrm,:,:,:) , 1 , fprefix , trim('output_wvar         ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%aut           (icrm,:,:,:) , 1 , fprefix , trim('output_aut          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%acc           (icrm,:,:,:) , 1 , fprefix , trim('output_acc          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%evpc          (icrm,:,:,:) , 1 , fprefix , trim('output_evpc         ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%evpr          (icrm,:,:,:) , 1 , fprefix , trim('output_evpr         ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%mlt           (icrm,:,:,:) , 1 , fprefix , trim('output_mlt          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%sub           (icrm,:,:,:) , 1 , fprefix , trim('output_sub          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%dep           (icrm,:,:,:) , 1 , fprefix , trim('output_dep          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%con           (icrm,:,:,:) , 1 , fprefix , trim('output_con          ') , (/'crm_nx','crm_ny','crm_nz'/)             , .false. , .false. )
        call dmdf_write( crm_output%cltot         (icrm)       , 1 , fprefix , trim('output_cltot        ')                                              , .false. , .false. )
        call dmdf_write( crm_output%cllow         (icrm)       , 1 , fprefix , trim('output_cllow        ')                                              , .false. , .false. )
        call dmdf_write( crm_output%clmed         (icrm)       , 1 , fprefix , trim('output_clmed        ')                                              , .false. , .false. )
        call dmdf_write( crm_output%clhgh         (icrm)       , 1 , fprefix , trim('output_clhgh        ')                                              , .false. , .false. )
        call dmdf_write( crm_output%precc         (icrm)       , 1 , fprefix , trim('output_precc        ')                                              , .false. , .false. )
        call dmdf_write( crm_output%precl         (icrm)       , 1 , fprefix , trim('output_precl        ')                                              , .false. , .false. )
        call dmdf_write( crm_output%precsc        (icrm)       , 1 , fprefix , trim('output_precsc       ')                                              , .false. , .false. )
        call dmdf_write( crm_output%precsl        (icrm)       , 1 , fprefix , trim('output_precsl       ')                                              , .false. , .false. )
        call dmdf_write( crm_output%cldtop        (icrm,:)     , 1 , fprefix , trim('output_cldtop       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qc_mean       (icrm,:)     , 1 , fprefix , trim('output_qc_mean      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qi_mean       (icrm,:)     , 1 , fprefix , trim('output_qi_mean      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qs_mean       (icrm,:)     , 1 , fprefix , trim('output_qs_mean      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qg_mean       (icrm,:)     , 1 , fprefix , trim('output_qg_mean      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qr_mean       (icrm,:)     , 1 , fprefix , trim('output_qr_mean      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%sltend        (icrm,:)     , 1 , fprefix , trim('output_sltend       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qltend        (icrm,:)     , 1 , fprefix , trim('output_qltend       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qcltend       (icrm,:)     , 1 , fprefix , trim('output_qcltend      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qiltend       (icrm,:)     , 1 , fprefix , trim('output_qiltend      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%cld           (icrm,:)     , 1 , fprefix , trim('output_cld          ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%gicewp        (icrm,:)     , 1 , fprefix , trim('output_gicewp       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%gliqwp        (icrm,:)     , 1 , fprefix , trim('output_gliqwp       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%mctot         (icrm,:)     , 1 , fprefix , trim('output_mctot        ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%mcup          (icrm,:)     , 1 , fprefix , trim('output_mcup         ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%mcdn          (icrm,:)     , 1 , fprefix , trim('output_mcdn         ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%mcuup         (icrm,:)     , 1 , fprefix , trim('output_mcuup        ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%mcudn         (icrm,:)     , 1 , fprefix , trim('output_mcudn        ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%mu_crm        (icrm,:)     , 1 , fprefix , trim('output_mu_crm       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%md_crm        (icrm,:)     , 1 , fprefix , trim('output_md_crm       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%du_crm        (icrm,:)     , 1 , fprefix , trim('output_du_crm       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%eu_crm        (icrm,:)     , 1 , fprefix , trim('output_eu_crm       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%ed_crm        (icrm,:)     , 1 , fprefix , trim('output_ed_crm       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%jt_crm        (icrm)       , 1 , fprefix , trim('output_jt_crm       ')                                              , .false. , .false. )
        call dmdf_write( crm_output%mx_crm        (icrm)       , 1 , fprefix , trim('output_mx_crm       ')                                              , .false. , .false. )
        call dmdf_write( crm_output%flux_qt       (icrm,:)     , 1 , fprefix , trim('output_flux_qt      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%fluxsgs_qt    (icrm,:)     , 1 , fprefix , trim('output_fluxsgs_qt   ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%tkez          (icrm,:)     , 1 , fprefix , trim('output_tkez         ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%tkesgsz       (icrm,:)     , 1 , fprefix , trim('output_tkesgsz      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%tkz           (icrm,:)     , 1 , fprefix , trim('output_tkz          ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%flux_u        (icrm,:)     , 1 , fprefix , trim('output_flux_u       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%flux_v        (icrm,:)     , 1 , fprefix , trim('output_flux_v       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%flux_qp       (icrm,:)     , 1 , fprefix , trim('output_flux_qp      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%precflux      (icrm,:)     , 1 , fprefix , trim('output_precflux     ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qt_ls         (icrm,:)     , 1 , fprefix , trim('output_qt_ls        ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qt_trans      (icrm,:)     , 1 , fprefix , trim('output_qt_trans     ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qp_trans      (icrm,:)     , 1 , fprefix , trim('output_qp_trans     ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qp_fall       (icrm,:)     , 1 , fprefix , trim('output_qp_fall      ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qp_src        (icrm,:)     , 1 , fprefix , trim('output_qp_src       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%qp_evp        (icrm,:)     , 1 , fprefix , trim('output_qp_evp       ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%t_ls          (icrm,:)     , 1 , fprefix , trim('output_t_ls         ') , (/'nlev'/)                                 , .false. , .false. )
        call dmdf_write( crm_output%prectend      (icrm)       , 1 , fprefix , trim('output_prectend     ')                                              , .false. , .false. )
        call dmdf_write( crm_output%precstend     (icrm)       , 1 , fprefix , trim('output_precstend    ')                                              , .false. , .false. )
        call dmdf_write( crm_output%taux          (icrm)       , 1 , fprefix , trim('output_taux         ')                                              , .false. , .false. )
        call dmdf_write( crm_output%tauy          (icrm)       , 1 , fprefix , trim('output_tauy         ')                                              , .false. , .false. )
        call dmdf_write( crm_output%z0m           (icrm)       , 1 , fprefix , trim('output_z0m          ')                                              , .false. , .false. )
        call dmdf_write( crm_output%subcycle_factor (icrm)       , 1 , fprefix , trim('output_subcycle_factor')                                              , .false. , .false. )
        call dmdf_write( crm_rad%qrad             (icrm,:,:,:) , 1 , fprefix , trim('rad_qrad            ') , (/'crm_nx_rad','crm_ny_rad','crm_nz    '/) , .false. , .false. )
        call dmdf_write( crm_rad%temperature      (icrm,:,:,:) , 1 , fprefix , trim('rad_temperature     ') , (/'crm_nx_rad','crm_ny_rad','crm_nz    '/) , .false. , .false. )
        call dmdf_write( crm_rad%qv               (icrm,:,:,:) , 1 , fprefix , trim('rad_qv              ') , (/'crm_nx_rad','crm_ny_rad','crm_nz    '/) , .false. , .false. )
        call dmdf_write( crm_rad%qc               (icrm,:,:,:) , 1 , fprefix , trim('rad_qc              ') , (/'crm_nx_rad','crm_ny_rad','crm_nz    '/) , .false. , .false. )
        call dmdf_write( crm_rad%qi               (icrm,:,:,:) , 1 , fprefix , trim('rad_qi              ') , (/'crm_nx_rad','crm_ny_rad','crm_nz    '/) , .false. , .false. )
        call dmdf_write( crm_rad%cld              (icrm,:,:,:) , 1 , fprefix , trim('rad_cld             ') , (/'crm_nx_rad','crm_ny_rad','crm_nz    '/) , .false. , .false. )
        call dmdf_write( crm_clear_rh             (icrm,:)     , 1 , fprefix , trim('crm_clear_rh        ') , (/'crm_nz'/)                               , .false. , .true.  )
      enddo
    endif
#if HAVE_MPI
    call mpi_barrier(mpi_comm_world,ierr)
#endif
  enddo

#if HAVE_MPI
  call mpi_finalize(ierr)
#endif

contains


  subroutine distr_indices(nTasks,nThreads,myThreadID,myTasks_beg,myTasks_end)
    implicit none
    integer, intent(in   ) :: nTasks
    integer, intent(in   ) :: nThreads
    integer, intent(in   ) :: myThreadID
    integer, intent(  out) :: myTasks_beg
    integer, intent(  out) :: myTasks_end
    real :: nper
    nper = real(nTasks)/nThreads
    myTasks_beg = nint( nper* myThreadID    )+1
    myTasks_end = nint( nper*(myThreadID+1) )
  end subroutine distr_indices


end program driver


