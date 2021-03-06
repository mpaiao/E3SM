! -----------------------------------------------------------------------------
! MODULE  accelerate_crm_mod
!   This module provides functionality to apply mean-state acceleration (MSA)
!   (Jones et al., 2015, doi:10.1002/2015MS000488) to the CRMs when using
!   superparameterization.
!
! PUBLIC SUBROUTINES:
!   crm_accel_nstop: adjusts 'nstop' in crm_module based on crm_accel_factor
!   accelerate_crm: calculates and applies MSA tendency to CRM
!
! PUBLIC MODULE VARIABLES:
!   logical  :: use_crm_accel - apply MSA if true (cam namelist variable)
!   real(crm_rknd) :: crm_accel_factor - MSA factor to use (cam namelist variable)
!
! REVISION HISTORY:
!   2018-Nov-01: Initial implementation
!   2019-Jan-30: Initial subroutine port to GPU using openacc directives
!
! CONTACT: Christopher Jones (christopher.jones@pnnl.gov)
! -----------------------------------------------------------------------------
module accelerate_crm_mod
    use grid, only: nx, ny
    use params, only: asyncid
    use params_kind, only: crm_rknd
    implicit none
    public

    real(crm_rknd), parameter :: coef = 1._crm_rknd / dble(nx * ny)  ! coefficient for horizontal averaging
    logical :: crm_accel_uv  ! (false) apply MSA only to scalar fields (T and QT)
                             ! (true) apply MSA to winds (U/V) and scalar fields

    ! public module variables
    logical :: use_crm_accel  ! use MSA if true
    real(crm_rknd) :: crm_accel_factor  ! 1 + crm_accel_factor = 'a' in Jones etal (2015)

    public :: use_crm_accel, crm_accel_factor
    public :: accelerate_crm
    public :: crm_accel_nstop

  contains


    subroutine crm_accel_nstop(nstop)
      ! Reduces nstop to appropriate value given crm_accel_factor.
      ! 
      ! To correctly apply mean-state acceleration in the crm_module/crm
      ! subroutine, nstop must be reduced to nstop / (1 + crm_accel_factor).
      ! This is equivalent to nstop = crm_run_time / dt_a, where 
      ! dt_a = crm_dt * (1 + crm_accel_factor) is the effective duration of 
      ! a mean-state accelerated time-step.
      !
      ! Argument(s):
      !  nstop (inout) - number of crm iterations to apply MSA
      ! -----------------------------------------------------------------------
      implicit none
  
      integer, intent(inout) :: nstop
  
      if (mod(nstop, int(1 + crm_accel_factor)) .ne. 0) then
        write(*,*) "CRM acceleration unexpected exception:"
        write(*,*) "(1+crm_accel_factor) does not divide equally into nstop"
        write(*,*) "nstop = ", nstop
        write(*,*) "crm_accel_factor = ", crm_accel_factor
        write(*,*) 'crm main: bad crm_accel_factor and nstop pair'
        stop
      else
        nstop = nstop / (1 + crm_accel_factor)
      endif
    end subroutine crm_accel_nstop


    subroutine accelerate_crm(ncrms, nstep, nstop, ceaseflag)
      ! Applies mean-state acceleration (MSA) to CRM
      !
      ! Applies MSA to the following crm fields:
      !   t, qv, qcl, qci, micro_field(:,:,:,index_water_vapor,:),
      !   u (optional), v (optional)
      ! Raises ceaseflag and aborts MSA if the magnitude of 
      ! the change in "t" exceeds 5K at any point.
      ! 
      ! Arguments:
      !   ncrms (in) - number of crm columns in this group
      !   nstep (in) - current crm iteration, needed only if 
      !                ceaseflag is triggered
      !   nstop (inout) - number of crm iterations, adjusted only
      !                   if ceaseflag is triggered
      !   ceaseflag (inout) - returns true if accelerate_crm aborted
      !                       before MSA applied; otherwise false
      ! Notes:
      !   micro_field(:,:,:,index_water_vapor,:) is the non-precipitating
      !     _total_ water mixing ratio for sam1mom microphysics.
      !   Intended to be called from crm subroutine in crm_module
      ! -----------------------------------------------------------------------
      use grid, only: nzm
      use vars, only: u, v, u0, v0, t0,q0, t,qcl,qci,qv
      use microphysics, only: micro_field, idx_qt=>index_water_vapor
      implicit none
      integer, intent(in   ) :: ncrms
      integer, intent(in   ) :: nstep
      integer, intent(inout) :: nstop
      logical, intent(inout) :: ceaseflag
      real(crm_rknd), allocatable :: ubaccel  (:,:)   ! u before applying MSA tendency
      real(crm_rknd), allocatable :: vbaccel  (:,:)   ! v before applying MSA tendency
      real(crm_rknd), allocatable :: tbaccel  (:,:)   ! t before applying MSA tendency
      real(crm_rknd), allocatable :: qtbaccel (:,:)  ! Non-precipitating qt before applying MSA tendency
      real(crm_rknd), allocatable :: ttend_acc(:,:) ! MSA adjustment of t
      real(crm_rknd), allocatable :: qtend_acc(:,:) ! MSA adjustment of qt
      real(crm_rknd), allocatable :: utend_acc(:,:) ! MSA adjustment of u
      real(crm_rknd), allocatable :: vtend_acc(:,:) ! MSA adjustment of v
      real(crm_rknd), allocatable :: qpoz     (:,:) ! total positive micro_field(:,:,k,idx_qt,:) in level k
      real(crm_rknd), allocatable :: qneg     (:,:) ! total negative micro_field(:,:,k,idx_qt,:) in level k
      real(crm_rknd) :: tmp  ! temporary variable for atomic updates
      integer i, j, k, icrm  ! iteration variables
      real(crm_rknd) :: factor, qt_res ! local variables for redistributing moisture
      real(crm_rknd) :: ttend_threshold ! threshold for ttend_acc at which MSA aborts
      real(crm_rknd) :: tmin  ! mininum value of t allowed (sanity factor)

      ttend_threshold = 5.  ! 5K, following UP-CAM implementation
      tmin = 50.  ! should never get below 50K in crm, following UP-CAM implementation

      allocate( ubaccel  (ncrms,nzm) )
      allocate( vbaccel  (ncrms,nzm) )
      allocate( tbaccel  (ncrms,nzm) )
      allocate( qtbaccel (ncrms,nzm) )
      allocate( ttend_acc(ncrms,nzm) )
      allocate( qtend_acc(ncrms,nzm) )
      allocate( utend_acc(ncrms,nzm) )
      allocate( vtend_acc(ncrms,nzm) )
      allocate( qpoz     (ncrms,nzm) )
      allocate( qneg     (ncrms,nzm) )
      !$omp target enter data map(alloc: ubaccel   )
      !$omp target enter data map(alloc: vbaccel   )
      !$omp target enter data map(alloc: tbaccel   )
      !$omp target enter data map(alloc: qtbaccel  )
      !$omp target enter data map(alloc: ttend_acc )
      !$omp target enter data map(alloc: qtend_acc )
      !$omp target enter data map(alloc: utend_acc )
      !$omp target enter data map(alloc: vtend_acc )
      !$omp target enter data map(alloc: qpoz      )
      !$omp target enter data map(alloc: qneg      )

      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      !! Compute the average among horizontal columns for each variable
      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

      !$omp target teams distribute parallel do collapse(2)
      do k = 1, nzm
        do icrm = 1, ncrms
          tbaccel(icrm,k) = 0
          qtbaccel(icrm,k) = 0
          if (crm_accel_uv) then
            ubaccel(icrm,k) = 0
            vbaccel(icrm,k) = 0
          endif
        enddo
      enddo
      !$omp target teams distribute parallel do collapse(4)
      do k = 1, nzm
        do j = 1 , ny
          do i = 1 , nx
            do icrm = 1, ncrms
              ! calculate tendency * dtn
              tmp = t(icrm,i,j,k) * coef
              !$omp atomic update
              tbaccel(icrm,k) = tbaccel(icrm,k) + tmp
              tmp = (qcl(icrm,i,j, k) + qci(icrm,i,j, k) + qv(icrm,i,j, k)) * coef
              !$omp atomic update
              qtbaccel(icrm,k) = qtbaccel(icrm,k) + tmp
              if (crm_accel_uv) then
                tmp = u(icrm,i,j,k) * coef
                !$omp atomic update
                ubaccel(icrm,k) = ubaccel(icrm,k) + tmp
                tmp = v(icrm,i,j,k) * coef
                !$omp atomic update
                vbaccel(icrm,k) = vbaccel(icrm,k) + tmp
              endif
            enddo
          enddo
        enddo
      enddo

      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      !! Compute the accelerated tendencies
      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

      !$omp target teams distribute parallel do collapse(2)
      do k = 1, nzm
        do icrm = 1, ncrms
          ttend_acc(icrm,k) = tbaccel(icrm,k) - t0(icrm,k)
          qtend_acc(icrm,k) = qtbaccel(icrm,k) - q0(icrm,k)
          if (crm_accel_uv) then
            utend_acc(icrm,k) = ubaccel(icrm,k) - u0(icrm,k)
            vtend_acc(icrm,k) = vbaccel(icrm,k) - v0(icrm,k)
          endif
          if (abs(ttend_acc(icrm,k)) > ttend_threshold) then
            ceaseflag = .true.
          endif
        enddo
      enddo

      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      !! Make sure it isn't insane
      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

      !$omp taskwait
      if (ceaseflag) then ! special case for dT/dt too large
        ! MSA will not be applied here or for the remainder of the CRM integration.
        ! nstop must be updated to ensure the CRM integration duration is unchanged.
        ! 
        ! The effective MSA timestep is dt_a = crm_dt * (1 + crm_accel_factor). When
        ! ceaseflag is triggered at nstep, we've taken (nstep - 1) previous steps of
        ! size crm_dt * (1 + crm_accel_factor). The current step, and all future
        ! steps, will revert to size crm_dt. Therefore, the total crm integration
        ! time remaining after this step is
        !     time_remaining = crm_run_time - (nstep - 1)* dt_a + crm_dt
        !     nsteps_remaining = time_remaining / crm_dt
        !     updated nstop = nstep + nsteps_remaining
        ! Because we set nstop = crm_run_time / dt_a in crm_accel_nstop, subbing
        ! crm_run_time = nstop * dt_a and working through algebra yields 
        !     updated nstop = nstop + (nstop - nstep + 1) * crm_accel_factor.
        write (*,*) 'accelerate_crm: mean-state acceleration not applied this step'
        write (*,*) 'crm: nstop increased from ', nstop, ' to ', int(nstop+(nstop-nstep+1)*crm_accel_factor)
        nstop = nstop + (nstop - nstep + 1)*crm_accel_factor ! only can happen once
        return
      endif

      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      !! Apply the accelerated tendencies
      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

      !$omp target teams distribute parallel do collapse(4)
      do k = 1, nzm
        do j = 1, ny
          do i = 1, nx
            do icrm = 1, ncrms
              ! don't let T go negative!
              t(icrm,i,j,k) = max(tmin, t(icrm,i,j,k) + crm_accel_factor * ttend_acc(icrm,k))
              if (crm_accel_uv) then
                u(icrm,i,j,k) = u(icrm,i,j,k) + crm_accel_factor * utend_acc(icrm,k) 
                v(icrm,i,j,k) = v(icrm,i,j,k) + crm_accel_factor * vtend_acc(icrm,k) 
              endif
              !$omp atomic update
              micro_field(icrm,i,j,k,idx_qt) = micro_field(icrm,i,j,k,idx_qt) + crm_accel_factor * qtend_acc(icrm,k)
            enddo
          enddo
        enddo
      enddo

      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      !! Fix negative micro and readjust among separate water species
      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

      !$omp target teams distribute parallel do collapse(2)
      do k = 1, nzm
        do icrm = 1, ncrms
          qpoz(icrm,k) = 0.
          qneg(icrm,k) = 0.
        enddo
      enddo
      ! separately accumulate positive and negative qt values in each layer k
      !$omp target teams distribute parallel do collapse(4)
      do k = 1, nzm
        do j = 1, ny
          do i = 1, nx
            do icrm = 1, ncrms
              if (micro_field(icrm,i,j,k,idx_qt) < 0.) then
                !$omp atomic update
                qneg(icrm,k) = qneg(icrm,k) + micro_field(icrm,i,j,k,idx_qt)
              else
                !$omp atomic update
                qpoz(icrm,k) = qpoz(icrm,k) + micro_field(icrm,i,j,k,idx_qt)
              endif
            enddo
          enddo
        enddo
      enddo
      !$omp target teams distribute parallel do collapse(4)
      do k = 1, nzm
        do j = 1 , ny
          do i = 1 , nx
            do icrm = 1, ncrms
              if (qpoz(icrm,k) + qneg(icrm,k) <= 0.) then
                ! all moisture depleted in layer
                micro_field(icrm,i,j,k,idx_qt) = 0.
                qv(icrm,i,j,k    ) = 0.
                qcl(icrm,i,j,k    ) = 0.
                qci(icrm,i,j,k    ) = 0.
              else
                ! Clip qt values at 0 and remove the negative excess in each layer
                ! proportionally from the positive qt fields in the layer
                factor = 1._crm_rknd + qneg(icrm,k) / qpoz(icrm,k)
                micro_field(icrm,i,j,k,idx_qt) = max(0._crm_rknd, micro_field(icrm,i,j,k,idx_qt) * factor)
                ! Partition micro_field == qv + qcl + qci following these rules:
                !    (1) attempt to satisfy purely by adjusting qv
                !    (2) adjust qcl and qci only if needed to ensure positivity
                if (micro_field(icrm,i,j,k,idx_qt) <= 0._crm_rknd) then
                  qv(icrm,i,j,k) = 0.
                  qcl(icrm,i,j,k) = 0.
                  qci(icrm,i,j,k) = 0.
                else
                  ! deduce qv as residual between qt - qcl - qci
                  qt_res = micro_field(icrm,i,j,k,idx_qt) - qcl(icrm,i,j,k) - qci(icrm,i,j,k)
                  qv(icrm,i,j,k) = max(0._crm_rknd, qt_res)
                  if (qt_res < 0._crm_rknd) then
                    ! qv was clipped; need to reduce qcl and qci accordingly
                    factor = 1._crm_rknd + qt_res / (qcl(icrm,i,j,k) + qci(icrm,i,j,k))
                    qcl(icrm,i,j,k) = qcl(icrm,i,j,k) * factor
                    qci(icrm,i,j,k) = qci(icrm,i,j,k) * factor
                  endif
                endif
              endif ! qpoz + qneg < 0.
            enddo ! i = 1, nx
          enddo ! j = 1, ny
        enddo ! k = 1, nzm
      enddo ! icrm = 1, ncrms

      !$omp target exit data map(delete: ubaccel   )
      !$omp target exit data map(delete: vbaccel   )
      !$omp target exit data map(delete: tbaccel   )
      !$omp target exit data map(delete: qtbaccel  )
      !$omp target exit data map(delete: ttend_acc )
      !$omp target exit data map(delete: qtend_acc )
      !$omp target exit data map(delete: utend_acc )
      !$omp target exit data map(delete: vtend_acc )
      !$omp target exit data map(delete: qpoz      )
      !$omp target exit data map(delete: qneg      )

      deallocate( ubaccel   )
      deallocate( vbaccel   )
      deallocate( tbaccel   )
      deallocate( qtbaccel  )
      deallocate( ttend_acc )
      deallocate( qtend_acc )
      deallocate( utend_acc )
      deallocate( vtend_acc )
      deallocate( qpoz      )
      deallocate( qneg      )

    end subroutine accelerate_crm
    
end module accelerate_crm_mod
