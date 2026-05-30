*--------------------------------------------------------------------------
*---- Class:    ZCL_SCM_PIR_UPDATE
*---- Purpose:  Background job that updates Purchase Info Records (PIRs)
*----           with pricing data received from FairMarkit.
*----
*---- Data Flow:
*----   1. Middleware calls the unmanaged API which inserts/updates staging
*----      records in ZASCM_FMKTPIRREQ, tagged with a batch UUID.
*----   2. The API's saver schedules this job with PriceBookId + BatchUUID.
*----   3. This job:
*----      a) Reads the batch from the staging CDS view.
*----      b) Looks up matching PIRs in S/4HANA via CDS view.
*----      c) Looks for condition record with Condition type PB00
*----      d) Updates each PIR condition record  with FairMarkit prices via the MM API.
*----      e) Updates each staging record's status (success / error).
*----      f) Saves a BAL application log attached to the APJ job.
*----
*---- Scenarios (mutually exclusive, controlled by job parameters):
*----   - BATCH:  Normal processing of a FairMarkit price batch.
*----   - RETRY:  Re-process previously failed staging records.
*----   - MAIL:   Trigger summary/notification email.
*--------------------------------------------------------------------------
CLASS zcl_scm_pir_update DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.

    INTERFACES if_apj_dt_exec_object.
    INTERFACES if_apj_rt_exec_object.

  PRIVATE SECTION.

    TYPES: tt_update TYPE TABLE FOR UPDATE zi_scm_fmkt_pirmodify.

*-------- APJ parameter selection names (must match job template) ------
    CONSTANTS cv_param_pbookid  TYPE if_apj_dt_exec_object=>ty_templ_def-selname VALUE 'P_PBID'.
    CONSTANTS cv_param_batchid  TYPE if_apj_dt_exec_object=>ty_templ_def-selname VALUE 'P_JBID'.
    CONSTANTS cv_param_retry    TYPE if_apj_dt_exec_object=>ty_templ_def-selname VALUE 'P_RETRY'.
    CONSTANTS cv_param_mailtrig TYPE if_apj_dt_exec_object=>ty_templ_def-selname VALUE 'P_MTRIG'.

*-------- Processing status values written back to the staging table ---
* Status 1 marks a staging record that is waiting for PIR processing.
    CONSTANTS cv_status_pending TYPE zscm_fmkt_status VALUE '1'.
* Status 3 marks a staging record whose PIR update ended with an error.
    CONSTANTS cv_status_error   TYPE zscm_fmkt_status VALUE '3'.
* Status 2 marks a staging record currently being handled by the retry run.
    CONSTANTS cv_status_reinpro TYPE zscm_fmkt_status VALUE '2'.
* Status 4 marks a staging record whose PIR update completed successfully.
    CONSTANTS cv_status_success TYPE zscm_fmkt_status VALUE '4'.

*-------- Instance data: parsed job parameters -------------------------
    DATA mv_pbookid   TYPE zi_scm_fmkt_pirmodify-pricebookid.
    DATA mv_batchid   TYPE zi_scm_fmkt_pirmodify-jobid.
    DATA mv_retry     TYPE abap_boolean.
    DATA mv_mail      TYPE abap_boolean.

*-------- Instance data: runtime job identity --------------------------
    DATA mv_job_count TYPE btcjobcnt.

*-------- Instance data: BAL logging -----------------------------------
* Stores the in-memory BAL log buffer used while the job is running.
    DATA mo_log    TYPE REF TO if_bali_log.
* Stores the BAL database persistence handle used when the log is saved.
    DATA mo_log_db TYPE REF TO if_bali_log_db.

*-----=== Parameter Handling ===========================================

*----- Parse APJ job parameter table into typed instance variables.
    METHODS fill_selection_param
      IMPORTING
        it_parameters TYPE if_apj_dt_exec_object=>tt_templ_val.

*----- Resolve the current background job's count number.
*----- Stored in staging records to trace which job processed them.
    METHODS resolve_job_count.

*-----=== BAL Application Logging ======================================

*----- Create a new BAL log instance with the given external ID.
*----- All subsequent log_message / log_bapiret calls append to it.
    METHODS init_log
      IMPORTING
        iv_external_id TYPE balnrext.

*----- Append a single T100 message to the current BAL log.
    METHODS log_message
      IMPORTING
        iv_severity   TYPE symsgty DEFAULT if_bali_constants=>c_severity_status
        iv_id         TYPE symsgid DEFAULT 'ZSCM_FAIRMARKIT'
        iv_number     TYPE symsgno
        iv_variable_1 TYPE symsgv OPTIONAL
        iv_variable_2 TYPE symsgv OPTIONAL
        iv_variable_3 TYPE symsgv OPTIONAL
        iv_variable_4 TYPE symsgv OPTIONAL.

*----- Append all messages from a BAPI return table to the BAL log.
    METHODS log_bapiret
      IMPORTING
        it_messages TYPE bapirettab.

*----- Persist the current BAL log to the DB (2nd connection) and
*----- attach it to the running APJ job.
    METHODS save_log.

*----- Check whether a Job is running right now to process Records
*----- This is to ensure we pick records left by dead jobs
    METHODS check_valid_for_retry
      RETURNING VALUE(rv_yes) TYPE abap_boolean.

*-----=== Batch Processing =============================================

*----- Main orchestration for the batch processing scenario.
    METHODS process_batch.

*----- Retry orchestration for the batch processing scenario.
    METHODS process_retry_batch.

*----- Update a single PIR with FairMarkit pricing data.
*----- Returns ABAP_TRUE on success, ABAP_FALSE on failure.
*----- Handles its own BAPI COMMIT / ROLLBACK per record.
    METHODS update_single_pir
      IMPORTING
        is_pinfoupdate    TYPE mmpur_inforecord
      RETURNING
        VALUE(rv_success) TYPE abap_boolean.

*----- Bulk-update staging record statuses via EML + COMMIT ENTITIES.
    METHODS update_staging_status
      IMPORTING
        it_modifications TYPE tt_update.

ENDCLASS.


CLASS zcl_scm_pir_update IMPLEMENTATION.


  METHOD if_apj_dt_exec_object~get_parameters.
*-------------------------------------------------------------------
*----- Define the job template parameters for the APJ framework.
*----- These appear in the 'Schedule Application Job' Fiori app
*----- and in the job template ZJOB_SCM_PIR_TEMPLATE.
*-------------------------------------------------------------------
    CONSTANTS:
      cv_de_pbookid  TYPE if_apj_dt_exec_object=>ty_templ_def-component_type VALUE 'ZSCM_FMKT_PBOOKID',
      cv_de_batchid  TYPE if_apj_dt_exec_object=>ty_templ_def-component_type VALUE 'ZSCM_FMKT_JOBID',
      cv_de_retry    TYPE if_apj_dt_exec_object=>ty_templ_def-component_type VALUE 'ZSCM_FMKT_RETRY',
      cv_de_mailtrig TYPE if_apj_dt_exec_object=>ty_templ_def-component_type VALUE 'ZSCM_FMKT_MTRIGGER'.

    et_parameter_def = VALUE #(
* --- Price Book ID: identifies the FairMarkit price book --------
      ( selname        = cv_param_pbookid
        kind           = if_apj_dt_exec_object=>parameter
        component_type = cv_de_pbookid
* TEXT-001 -- display label for the Price Book ID parameter.
        param_text     = TEXT-001
        changeable_ind = abap_true
        mandatory_ind  = abap_false
        datatype       = 'C'
        length         = 32 )

* --- Batch UUID: isolates this job's records --------------------
      ( selname        = cv_param_batchid
        kind           = if_apj_dt_exec_object=>parameter
        component_type = cv_de_batchid
* TEXT-002 -- display label for the Batch UUID parameter.
        param_text     = TEXT-002
        changeable_ind = abap_true
        mandatory_ind  = abap_false
        datatype       = 'X'
        length         = 16 )

*-------- Retry flag: re-process failed records ----------------------
      ( selname        = cv_param_retry
        kind           = if_apj_dt_exec_object=>parameter
        component_type = cv_de_retry
* TEXT-003 -- display label for the retry parameter.
        param_text     = TEXT-003
        changeable_ind = abap_true
        mandatory_ind  = abap_false
        datatype       = 'C'
        length         = 1 )

*-------- Mail trigger: send notification email ----------------------
      ( selname        = cv_param_mailtrig
        kind           = if_apj_dt_exec_object=>parameter
        component_type = cv_de_mailtrig
* TEXT-004 -- display label for the mail-trigger parameter.
        param_text     = TEXT-004
        changeable_ind = abap_true
        mandatory_ind  = abap_false
        datatype       = 'C'
        length         = 1 ) ).
  ENDMETHOD.


  METHOD if_apj_rt_exec_object~execute.
*-------------------------------------------------------------------
*----- Entry point called by the APJ framework when the job runs.
*----- Parses parameters and routes to the correct scenario.
*----- Only one scenario is active per job execution.
*-------------------------------------------------------------------

*----- Resolve the background job's count for audit tracking.
    resolve_job_count( ).

*----- Parse job parameters into typed instance variables.
    fill_selection_param( it_parameters ).

*----- Route to the correct processing scenario.
    IF mv_pbookid IS NOT INITIAL AND mv_batchid IS NOT INITIAL.
*-------- Normal batch processing: update PIRs with FairMarkit prices.
      process_batch( ).

    ELSEIF mv_retry = abap_true.
*----- TODO: Retry previously failed records (status = cv_status_error,
*-----       numberofretries < 9). Re-runs the same PIR update logic
*-----       and increments the retry counter on persistent failure.

    ELSEIF mv_mail = abap_true.
*----- TODO: Trigger summary/notification email with processing results.

    ENDIF.
  ENDMETHOD.


  METHOD fill_selection_param.
*-------------------------------------------------------------------
*----- Map APJ parameter table entries to typed instance variables.
*----- Uses OPTIONAL to gracefully handle missing parameters
*----- (returns initial value instead of raising an exception).
*-------------------------------------------------------------------
    IF it_parameters IS INITIAL.
      RETURN.
    ENDIF.

    mv_pbookid = VALUE #( it_parameters[ selname = cv_param_pbookid  ]-low OPTIONAL ).
    mv_batchid = VALUE #( it_parameters[ selname = cv_param_batchid  ]-low OPTIONAL ).
    mv_retry   = VALUE #( it_parameters[ selname = cv_param_retry    ]-low OPTIONAL ).
    mv_mail    = VALUE #( it_parameters[ selname = cv_param_mailtrig ]-low OPTIONAL ).
  ENDMETHOD.


  METHOD resolve_job_count.
*-------------------------------------------------------------------
*----- Get the current job's count number from the APJ runtime.
*----- This value replaces the batch UUID in the staging records
*----- after processing, so each record can be traced back to the
*----- exact background job that handled it.
*-------------------------------------------------------------------
    CALL FUNCTION 'GET_JOB_RUNTIME_INFO'
      IMPORTING
        jobcount = mv_job_count
      EXCEPTIONS
        OTHERS   = 99.

    IF sy-subrc <> 0.
*----- Non-critical: if we can't get the job count, clear it.
*----- Processing continues; records just won't have a job reference.
      CLEAR mv_job_count.
    ENDIF.
  ENDMETHOD.


  METHOD init_log.
*-------------------------------------------------------------------
*----- Create a new BAL log instance with the given external ID.
*----- A single log is used for the entire batch — individual
*----- messages include the item ID as a variable for tracing.
*-----
*----- Uses object ZSCM_FMKT_PIRLOG / subobject ZSCM_FMKT_SUBOBJ
*----- (must be registered in SLG0 transaction).
*-------------------------------------------------------------------
    TRY.
        DATA(lo_header) = cl_bali_header_setter=>create(
          object      = 'ZSCM_FMKT_PIRLOG'
          subobject   = 'ZSCM_FMKT_SUBOBJ'
          external_id = iv_external_id ).

*----- Create the in-memory log buffer.
        mo_log = cl_bali_log=>create_with_header( header = lo_header ).

*----- Get the DB persistence handle (singleton).
        mo_log_db = cl_bali_log_db=>get_instance( ).

      CATCH cx_bali_runtime INTO DATA(lx_bal).
*----- Logging setup failure is non-critical for processing,
*----- but we raise it as a MESSAGE so it appears in the APJ job log.
        MESSAGE lx_bal->get_longtext( ) TYPE 'W'.
    ENDTRY.
  ENDMETHOD.


  METHOD log_message.
*-------------------------------------------------------------------
*----- Append a single T100 message to the current BAL log.
*----- Safe to call even if init_log failed (no-op if unbound).
*-------------------------------------------------------------------
    IF mo_log IS NOT BOUND.
      RETURN.
    ENDIF.

    TRY.
        mo_log->add_item(
          cl_bali_message_setter=>create(
            severity   = iv_severity
            id         = iv_id
            number     = iv_number
            variable_1 = iv_variable_1
            variable_2 = iv_variable_2
            variable_3 = iv_variable_3
            variable_4 = iv_variable_4 ) ).
      CATCH cx_bali_runtime.
*----- Logging failure is non-critical; processing continues.
    ENDTRY.
  ENDMETHOD.


  METHOD log_bapiret.
*-------------------------------------------------------------------
*----- Bulk-append all messages from a BAPI return table (BAPIRET2)
*----- to the current BAL log. Typically called after a failed
*----- cl_mm_inforec_handler_api->update() to capture all API
*----- error/warning/info messages.
*-------------------------------------------------------------------
    IF mo_log IS NOT BOUND OR it_messages IS INITIAL.
      RETURN.
    ENDIF.

    TRY.
        mo_log->add_messages_from_bapirettab( message_table = it_messages ).
      CATCH cx_bali_runtime.
*----- Logging failure is non-critical.
    ENDTRY.
  ENDMETHOD.


  METHOD save_log.
*-------------------------------------------------------------------
*----- Persist the current BAL log to the database using a 2nd
*----- DB connection. This ensures the log is saved even if the
*----- main LUW is rolled back. The log is attached to the current
*----- APJ job for visibility in the 'Application Jobs' Fiori app.
*-------------------------------------------------------------------
    IF mo_log IS NOT BOUND OR mo_log_db IS NOT BOUND.
      RETURN.
    ENDIF.

    TRY.
        mo_log_db->save_log_2nd_db_connection(
          log                        = mo_log ).
      CATCH cx_bali_runtime INTO DATA(lx_bal).
* Raise a final warning if the BAL log cannot be persisted.
        MESSAGE lx_bal->get_longtext( ) TYPE 'W'.
    ENDTRY.
  ENDMETHOD.


  METHOD process_batch.
*-------------------------------------------------------------------
*----- Main batch processing orchestration:
*-----
*----- 1. Init batch-level BAL log
*----- 2. Fetch staging records for this batch (by pricebook + UUID)
*----- 3. Fetch matching PIR records from S/4HANA
*----- 4. For each staging record:
*-----    a. Find matching PIRs (same vendor/material/org)
*-----    b. Validate currency compatibility
*-----    c. Update each PIR with FairMarkit prices
*-----    d. Track per-record success/error status
*----- 5. Bulk-update staging record statuses via EML
*----- 6. Save log
*-------------------------------------------------------------------
    DATA: lt_modifications TYPE TABLE FOR UPDATE zi_scm_fmkt_pirmodify,
          lv_tabix         TYPE sy-tabix VALUE 1.

*----- Build external ID for the batch log.
*----- Format: <PriceBook truncated>_<time> to fit BALNREXT (CHAR 22).
    DATA(lv_log_ext_id) = CONV balnrext(
      |{ mv_pbookid(12) }_{ sy-uzeit }| ).

*-------- 1. Initialize batch-level log --------------------------------
    init_log( lv_log_ext_id ).

*-------- 2. Fetch staging records tagged with this batch UUID ----------
*----- The batch UUID was assigned by cba_piritems and ensures this job
*----- only processes the exact 1000 records from its triggering API call.
    SELECT pricebookid,
           itemid,
           vendor,
           material,
           purchaseorganization,
           priceunit,
           netprice,
           currency,
           status,
           numberofretries
      FROM zi_scm_fmkt_pirmodify
      WHERE pricebookid = @mv_pbookid
        AND jobid       = @mv_batchid
      INTO TABLE @DATA(lt_staging).

    IF sy-subrc <> 0 OR lt_staging IS INITIAL.
*----- No staging records found — likely a stale or duplicate job.
*----- Log the error and exit without updating anything.
      log_message( iv_severity = if_bali_constants=>c_severity_information
                   iv_number   = 002 ).
      save_log( ).
      RETURN.
    ENDIF.

*-------- 3. Fetch existing PIR records from S/4HANA --------------------
*----- FOR ALL ENTRIES lookup: finds all PIRs where the supplier,
*----- material, and purchasing organization match any staging record.
*----- One staging record can match multiple PIRs (different plants).
*----- WITH PRIVILEGED ACCESS bypasses CDS access control for the
*----- background job context.
    SELECT popd~purchasinginforecord,
           popd~purchasinginforecordcategory,
           popd~purchasingorganization,
           popd~plant,
           popd~currency,
           popd~materialpriceunitqty,
           popd~supplier,
           popd~material,
           popd~purchaseorderpriceunit,
           popd~netpriceamount,
           popd~materialplanneddeliverydurn,
           ppcn~conditionrecord,
           ppcn~conditionsequentialnumber,
           ppcn~conditionapplication,
           ppcn~conditiontype,
           ppcn~conditionvalidityenddate,
           ppcn~conditionvaliditystartdate,
           ppcn~createdbyuser,
           ppcn~creationdate,
           ppcn~conditiontextid,
           ppcn~pricingscaletype,
           ppcn~pricingscalebasis,
           ppcn~conditionscalequantity,
           ppcn~conditionscalequantityunit,
           ppcn~conditionscaleamount,
           ppcn~conditionscaleamountcurrency,
           ppcn~conditioncalculationtype,
           ppcn~conditionratevalue,
           ppcn~conditionratevalueunit,
           ppcn~conditionrateratiounit,
           ppcn~conditionrateratio,
           ppcn~conditioncurrency,
           ppcn~conditionrateamount,
           ppcn~conditionquantity,
           ppcn~conditionquantityunit,
           ppcn~conditiontobaseqtynmrtr,
           ppcn~conditiontobaseqtydnmntr,
           ppcn~baseunit,
           ppcn~conditionlowerlimit,
           ppcn~conditionupperlimit,
           ppcn~conditionalternativecurrency,
           ppcn~conditionexclusion,
           ppcn~conditionisdeleted,
           ppcn~additionalvaluedays,
           ppcn~fixedvaluedate,
           ppcn~paymentterms,
           ppcn~cndnmaxnumberofsalesorders,
           ppcn~minimumconditionbasisvalue,
           ppcn~maximumconditionbasisvalue,
           ppcn~maximumconditionamount,
           ppcn~incrementalscale,
           ppcn~pricingscaleline,
           ppcn~conditionreleasestatus
      FROM a_purginforecdorgplantdata
      WITH PRIVILEGED ACCESS  AS popd
      INNER JOIN a_purinforecdprcgcndnvalidity
      WITH PRIVILEGED ACCESS AS ppcv
      ON popd~purchasinginforecord  = ppcv~purchasinginforecord
      AND  popd~purchasinginforecordcategory = ppcv~purchasinginforecordcategory
      AND popd~purchasingorganization = ppcv~purchasingorganization
      INNER JOIN a_purinforecdprcgcndn
      WITH PRIVILEGED ACCESS AS ppcn
      ON ppcv~conditionrecord = ppcn~conditionrecord
      FOR ALL ENTRIES IN @lt_staging
      WHERE popd~supplier               = @lt_staging-vendor
        AND popd~material               = @lt_staging-material
        AND popd~purchasingorganization = @lt_staging-purchaseorganization
        AND ppcv~purchasingorganization = @lt_staging-purchaseorganization
        AND ppcv~conditionvalidityenddate >= @sy-datum
        AND ppcv~conditionvaliditystartdate <= @sy-datum
        AND ppcn~conditiontype EQ 'PB00'
      INTO TABLE @DATA(lt_pir).

    IF sy-subrc <> 0 OR lt_pir IS INITIAL.
*----- No matching PIR records exist in S/4HANA.
*----- Mark ALL staging records as error and exit.
      log_message( iv_severity = if_bali_constants=>c_severity_error
                   iv_number   = 002 ).

      lt_modifications = VALUE #(
        FOR <ls_stg_err> IN lt_staging
        ( %key-pricebookid       = <ls_stg_err>-pricebookid
          %key-itemid            = <ls_stg_err>-itemid
          jobid                  = mv_job_count
          status                 = cv_status_error
          messagelognumber       = lv_log_ext_id
          %control = VALUE #(
            jobid            = if_abap_behv=>mk-on
            status           = if_abap_behv=>mk-on
            messagelognumber = if_abap_behv=>mk-on ) ) ).

      update_staging_status( lt_modifications ).
      save_log( ).
      RETURN.
    ENDIF.

    SORT lt_pir BY supplier material purchasingorganization.

*-------- 4. Process each staging record --------------------------------
    LOOP AT lt_staging ASSIGNING FIELD-SYMBOL(<ls_stg>).

*----- Adding Identification for Error Log: Pricebook ID + Item ID
      log_message(
            iv_severity   = if_bali_constants=>c_severity_warning
            iv_number     = 007
            iv_variable_1 = CONV #( <ls_stg>-pricebookid )
            iv_variable_2 = CONV #( <ls_stg>-itemid ) ).

*----- Track per-record outcome.
* This flag records whether at least one matching PIR was found for the staging item.
      DATA(lv_pir_found) = abap_false.
* This flag records whether all attempted PIR updates succeeded for the staging item.
      DATA(lv_all_ok)    = abap_true.

*--- Read to GET Index of first data as it is sorted anyway
*--- And then we can add index in loop to control efficiency of nested loop - optimized performance

      lv_tabix = line_index( lt_pir[ supplier               = <ls_stg>-vendor
                                     material               = <ls_stg>-material
                                     purchasingorganization = <ls_stg>-purchaseorganization ] ).

*----- Inner loop: find all PIRs matching this staging record's
*----- supplier + material + purchasing organization combination.
*----- Loop Only if a record is found
      IF lv_tabix > 0.
        LOOP AT lt_pir
        ASSIGNING FIELD-SYMBOL(<ls_pir>)
        FROM lv_tabix.

*----- The moment It does not find this combination - No need to look into other entries
*----- As it is already sorted and there is no chance of an entry being there somewhere after this
          IF <ls_pir>-supplier               <> <ls_stg>-vendor
          OR <ls_pir>-material               <> <ls_stg>-material
          OR <ls_pir>-purchasingorganization <> <ls_stg>-purchaseorganization.
            EXIT.
          ENDIF.


          lv_pir_found = abap_true.

*-------- Validate: currency must match between S/4 and FairMarkit --
*----- If currencies differ, the price comparison is meaningless.
*----- Log the mismatch and skip this PIR (continue to next).
          IF <ls_pir>-currency <> <ls_stg>-currency.
            log_message(
              iv_severity   = if_bali_constants=>c_severity_error
              iv_number     = 005
              iv_variable_1 = CONV #( <ls_pir>-currency )
              iv_variable_2 = CONV #( <ls_stg>-currency ) ).
            lv_all_ok = abap_false.
            CONTINUE.
          ENDIF.

*-------- Validate: Netprice and Priceunit different between S/4 and FairMarkit --
*----- If they are equal, the update is meaningless, price already up to date.
*----- Mark as Success and skip this PIR (continue to next).
          IF <ls_pir>-netpriceamount EQ <ls_stg>-netprice
          AND <ls_pir>-materialpriceunitqty EQ <ls_stg>-priceunit.
            log_message(
               iv_severity   = if_bali_constants=>c_severity_status
               iv_number     = 008
               iv_variable_1 = CONV #( <ls_pir>-purchasinginforecord ) ).
            lv_all_ok = abap_true.
            CONTINUE.
          ENDIF.

*-------- Update PIR with FairMarkit pricing data --------------------
          <ls_pir>-conditionratevalue = <ls_pir>-conditionrateamount = <ls_stg>-netprice.

          lv_all_ok = update_single_pir(
            is_pinfoupdate = VALUE #(
                             general_data-data-purchasinginforecord = <ls_pir>-purchasinginforecord
                             purchasing_org_data = VALUE #( (
                                                   data = VALUE #(
                                                   purchasinginforecord           = <ls_pir>-purchasinginforecord
                                                   purchasinginforecordcategory   = <ls_pir>-purchasinginforecordcategory
                                                   purchasingorganization         = <ls_pir>-purchasingorganization
                                                   plant                          = <ls_pir>-plant
                                                   materialpriceunitqty           = <ls_pir>-materialpriceunitqty
                                                   purchaseorderpriceunit         = <ls_pir>-purchaseorderpriceunit
                                                                 )
                                                   datax = VALUE #(
                                                   purchasinginforecord           = abap_true
                                                   purchasinginforecordcategory   = abap_true
                                                   purchasingorganization         = abap_true
                                                   plant                          = abap_true
                                                   materialpriceunitqty           = abap_true
                                                   purchaseorderpriceunit         = abap_true
                                                                 )
                                                   condition_amount = VALUE #( ( CORRESPONDING #( <ls_pir> ) ) )
                                                          ) )
* The update payload now contains the FairMarkit price that will be sent to the MM Info Record API.
                                    ) ).
* End the loop over matching PIR records for the current staging item.
        ENDLOOP.
      ENDIF.

*-------- Determine final status for this staging record ---------------
      DATA(lv_status) = COND zscm_fmkt_status(
        WHEN ( lv_pir_found = abap_false OR lv_all_ok = abap_false )
        THEN cv_status_error
        ELSE cv_status_success ).

*----- Log if no PIR was found for this item.
      IF lv_pir_found = abap_false.
        log_message(
          iv_severity   = if_bali_constants=>c_severity_error
          iv_number     = 006
          iv_variable_1 = CONV #( |Supplier:{ <ls_stg>-vendor }| )
          iv_variable_2 = CONV #( |Material:{ <ls_stg>-material }| )
          iv_variable_3 = CONV #( |Pur. Org:{ <ls_stg>-purchaseorganization }| ) ).
      ENDIF.

*----- Queue the status update for this record.
*----- All updates are collected and applied in one bulk EML call.
      lt_modifications =  VALUE #( (
        %key-pricebookid       = <ls_stg>-pricebookid
        %key-itemid            = <ls_stg>-itemid
        jobid                  = mv_job_count
        status                 = lv_status
        messagelognumber       = lv_log_ext_id
        %control = VALUE #(
          jobid            = if_abap_behv=>mk-on
          status           = if_abap_behv=>mk-on
          messagelognumber = if_abap_behv=>mk-on )
      ) ).

*-------- 5. update staging record statuses via EML ------------
*-------- We can not Update one by one as there is a risk of failures
*-------- Also heartbeat needs to be updated so other jobs can check whether in process or dead.
      update_staging_status( lt_modifications ).
      save_log( ).
* End the loop over staging records selected for processing.
    ENDLOOP.
  ENDMETHOD.


  METHOD update_single_pir.
*-------------------------------------------------------------------
*----- Update a single Purchase Info Record via the MM Info Record
*----- Handler API. Each call is followed by an explicit BAPI
*----- COMMIT or ROLLBACK to ensure clean LUW boundaries per PIR.
*-----
*----- Fields updated with FairMarkit values:
*-----   - Net Price Amount
*-----   - Currency
*-----   - Material Price Unit Quantity (price per N units)
*-----
*----- Fields NOT updated (no FairMarkit data available):
*-----   - Purchase Order Price Unit (UoM)
*-------------------------------------------------------------------

*----- Get a fresh API instance per call.
*----- The API may buffer state internally, so a new instance
*----- ensures isolation between consecutive updates.
    DATA(lo_new_inforec_handler) = cl_mm_pur_info_record_handler=>create(  ).

    CALL METHOD lo_new_inforec_handler->if_mm_pur_info_record_handler~process
      EXPORTING
        is_inforecord = is_pinfoupdate
        iv_info_upd   = 'X'
        iv_cprog      = 'ODATA_API'
      IMPORTING
        ev_error      = DATA(lv_error)
        et_messages   = DATA(lt_messages).


*-------- FAILURE: log all API messages and rollback -----------------
    DELETE lt_messages WHERE type = 'W'.
    IF lt_messages IS NOT INITIAL.
      log_bapiret( lt_messages ).
    ELSE.
      IF lv_error IS INITIAL.
        log_message(
          iv_number     = 009
          iv_variable_3 = CONV #( is_pinfoupdate-general_data-data-purchasinginforecord )
        ).
      ENDIF.
    ENDIF.

    IF lv_error IS NOT INITIAL.
      rv_success = abap_false.
    ELSE.
      rv_success = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD update_staging_status.
*-------------------------------------------------------------------
*----- Bulk-update the processing status of staging records via
*----- EML (Entity Manipulation Language) against the managed BO
*----- ZI_SCM_FMKT_PIRMODIFY.
*-----
*----- Uses MODIFY ENTITIES + COMMIT ENTITIES (not direct SQL)
*----- to go through the RAP framework, which handles locking.
*-----
*----- This runs AFTER all BAPI PIR updates are committed, so
*----- there is no interference between BAPI and EML commits.
*-------------------------------------------------------------------
    IF it_modifications IS INITIAL.
      RETURN.
    ENDIF.

    DATA(lt_modification) = it_modifications.

*----- Stage the updates in the RAP transactional buffer.
    MODIFY ENTITIES OF zi_scm_fmkt_pirmodify
      ENTITY zi_scm_fmkt_pirmodify
        UPDATE FIELDS ( status messagelognumber jobid )
        WITH lt_modification
      FAILED   DATA(ls_failed)
      REPORTED DATA(ls_reported).

*----- Persist the staged changes to the database.
    COMMIT ENTITIES RESPONSE OF zi_scm_fmkt_pirmodify
      FAILED   DATA(ls_failed_commit)
      REPORTED DATA(ls_reported_commit).

*----- Log any commit-level failures.
*----- These indicate a system-level problem (lock conflicts, etc.),
*----- not a business logic error.
    IF ls_failed_commit IS NOT INITIAL.
      LOOP AT ls_reported_commit-zi_scm_fmkt_pirmodify
        ASSIGNING FIELD-SYMBOL(<ls_rep>)
        WHERE %msg IS BOUND.
        log_message(
          iv_severity   = if_bali_constants=>c_severity_error
* Message 007 captures status-update failures returned by the RAP commit.
          iv_number     = 007
          iv_variable_1 = CONV #( <ls_rep>-%msg->if_message~get_text( ) ) ).
      ENDLOOP.
    ENDIF.
  ENDMETHOD.

  METHOD process_retry_batch.
*-------------------------------------------------------------------
*----- Main batch processing orchestration:
*-----
*----- 1. Init batch-level BAL log
*----- 2. Fetch staging records for this batch (by pricebook + UUID)
*----- 3. Fetch matching PIR records from S/4HANA
*----- 4. For each staging record:
*-----    a. Find matching PIRs (same vendor/material/org)
*-----    b. Validate currency compatibility
*-----    c. Update each PIR with FairMarkit prices
*-----    d. Track per-record success/error status
*----- 5. Bulk-update staging record statuses via EML
*----- 6. Save log
*-------------------------------------------------------------------
    DATA: lt_modifications TYPE TABLE FOR UPDATE zi_scm_fmkt_pirmodify,
          lv_tabix         TYPE sy-tabix VALUE 1.

*-------- 1. Initialize batch-level log --------------------------------
    DATA(lv_retry_all) = check_valid_for_retry(  ).

*----- Build external ID for the batch log.
*----- Format: <PriceBook truncated>_<time> to fit BALNREXT (CHAR 22).
    DATA(lv_log_ext_id) = CONV balnrext(
      |RETRY:{ mv_job_count }_{ sy-datum }{ sy-uzeit }| ).

*-------- 1. Initialize batch-level log --------------------------------
    init_log( lv_log_ext_id ).

*-------- 2. Fetch staging records tagged with this batch UUID ----------
*----- The batch UUID was assigned by cba_piritems and ensures this job
*----- only processes the exact 1000 records from its triggering API call.
    IF lv_retry_all EQ abap_true.
      SELECT pricebookid,
             itemid,
             vendor,
             material,
             purchaseorganization,
             priceunit,
             netprice,
             currency,
             status,
             numberofretries
        FROM zi_scm_fmkt_pirmodify
        WHERE numberofretries < 3
        AND status < @cv_status_success
        INTO TABLE @DATA(lt_staging).

      IF sy-subrc <> 0 OR lt_staging IS INITIAL.
*----- No staging records found — likely a stale or duplicate job.
*----- Log the error and exit without updating anything.
        log_message( iv_severity = if_bali_constants=>c_severity_status
                     iv_number   = 010 ).
        save_log( ).
        RETURN.
      ENDIF.
    ELSE.
      SELECT pricebookid,
             itemid,
             vendor,
             material,
             purchaseorganization,
             priceunit,
             netprice,
             currency,
             status,
             numberofretries
        FROM zi_scm_fmkt_pirmodify
        WHERE numberofretries < 3
        AND status = @cv_status_error
        INTO TABLE @lt_staging.

      IF sy-subrc <> 0 OR lt_staging IS INITIAL.
*----- No staging records found — likely a stale or duplicate job.
*----- Log the error and exit without updating anything.
        log_message( iv_severity = if_bali_constants=>c_severity_status
                     iv_number   = 010 ).
        save_log( ).
        RETURN.
      ENDIF.
    ENDIF.


*-------- 3. Fetch existing PIR records from S/4HANA --------------------
*----- FOR ALL ENTRIES lookup: finds all PIRs where the supplier,
*----- material, and purchasing organization match any staging record.
*----- One staging record can match multiple PIRs (different plants).
*----- WITH PRIVILEGED ACCESS bypasses CDS access control for the
*----- background job context.
    SELECT popd~purchasinginforecord,
           popd~purchasinginforecordcategory,
           popd~purchasingorganization,
           popd~plant,
           popd~currency,
           popd~materialpriceunitqty,
           popd~supplier,
           popd~material,
           popd~purchaseorderpriceunit,
           popd~netpriceamount,
           popd~materialplanneddeliverydurn,
           ppcn~conditionrecord,
           ppcn~conditionsequentialnumber,
           ppcn~conditionapplication,
           ppcn~conditiontype,
           ppcn~conditionvalidityenddate,
           ppcn~conditionvaliditystartdate,
           ppcn~createdbyuser,
           ppcn~creationdate,
           ppcn~conditiontextid,
           ppcn~pricingscaletype,
           ppcn~pricingscalebasis,
           ppcn~conditionscalequantity,
           ppcn~conditionscalequantityunit,
           ppcn~conditionscaleamount,
           ppcn~conditionscaleamountcurrency,
           ppcn~conditioncalculationtype,
           ppcn~conditionratevalue,
           ppcn~conditionratevalueunit,
           ppcn~conditionrateratiounit,
           ppcn~conditionrateratio,
           ppcn~conditioncurrency,
           ppcn~conditionrateamount,
           ppcn~conditionquantity,
           ppcn~conditionquantityunit,
           ppcn~conditiontobaseqtynmrtr,
           ppcn~conditiontobaseqtydnmntr,
           ppcn~baseunit,
           ppcn~conditionlowerlimit,
           ppcn~conditionupperlimit,
           ppcn~conditionalternativecurrency,
           ppcn~conditionexclusion,
           ppcn~conditionisdeleted,
           ppcn~additionalvaluedays,
           ppcn~fixedvaluedate,
           ppcn~paymentterms,
           ppcn~cndnmaxnumberofsalesorders,
           ppcn~minimumconditionbasisvalue,
           ppcn~maximumconditionbasisvalue,
           ppcn~maximumconditionamount,
           ppcn~incrementalscale,
           ppcn~pricingscaleline,
           ppcn~conditionreleasestatus
      FROM a_purginforecdorgplantdata
      WITH PRIVILEGED ACCESS  AS popd
      INNER JOIN a_purinforecdprcgcndnvalidity
      WITH PRIVILEGED ACCESS AS ppcv
      ON popd~purchasinginforecord  = ppcv~purchasinginforecord
      AND  popd~purchasinginforecordcategory = ppcv~purchasinginforecordcategory
      AND popd~purchasingorganization = ppcv~purchasingorganization
      INNER JOIN a_purinforecdprcgcndn
      WITH PRIVILEGED ACCESS AS ppcn
      ON ppcv~conditionrecord = ppcn~conditionrecord
      FOR ALL ENTRIES IN @lt_staging
      WHERE popd~supplier               = @lt_staging-vendor
        AND popd~material               = @lt_staging-material
        AND popd~purchasingorganization = @lt_staging-purchaseorganization
        AND ppcv~purchasingorganization = @lt_staging-purchaseorganization
        AND ppcv~conditionvalidityenddate >= @sy-datum
        AND ppcv~conditionvaliditystartdate <= @sy-datum
        AND ppcn~conditiontype EQ 'PB00'
      INTO TABLE @DATA(lt_pir).

    IF sy-subrc <> 0 OR lt_pir IS INITIAL.
*----- No matching PIR records exist in S/4HANA.
*----- Mark ALL staging records as error and exit.
      log_message( iv_severity = if_bali_constants=>c_severity_error
                   iv_number   = 002 ).

      lt_modifications = VALUE #(
        FOR <ls_stg_err> IN lt_staging
        ( %key-pricebookid       = <ls_stg_err>-pricebookid
          %key-itemid            = <ls_stg_err>-itemid
          jobid                  = mv_job_count
          status                 = cv_status_error
          messagelognumber       = lv_log_ext_id
          %control = VALUE #(
            jobid            = if_abap_behv=>mk-on
            messagelognumber = if_abap_behv=>mk-on ) ) ).

      update_staging_status( lt_modifications ).
      save_log( ).
      RETURN.
    ENDIF.

*---- Retry In Progress
    lt_modifications = VALUE #(
        FOR <ls_stg_err> IN lt_staging
        ( %key-pricebookid       = <ls_stg_err>-pricebookid
          %key-itemid            = <ls_stg_err>-itemid
          jobid                  = mv_job_count
          status                 = cv_status_reinpro
          messagelognumber       = lv_log_ext_id
          %control = VALUE #(
            jobid            = if_abap_behv=>mk-on
            messagelognumber = if_abap_behv=>mk-on ) ) ).
    update_staging_status( lt_modifications ).

    SORT lt_pir BY supplier material purchasingorganization.

*-------- 4. Process each staging record --------------------------------
    LOOP AT lt_staging ASSIGNING FIELD-SYMBOL(<ls_stg>).
      lv_tabix = sy-tabix.

*----- Adding Identification for Error Log: Pricebook ID + Item ID
      log_message(
            iv_severity   = if_bali_constants=>c_severity_warning
            iv_number     = 007
            iv_variable_1 = CONV #( <ls_stg>-pricebookid )
            iv_variable_2 = CONV #( <ls_stg>-itemid ) ).

*----- Track per-record outcome.
* This flag records whether at least one matching PIR was found for the staging item.
      DATA(lv_pir_found) = abap_false.
* This flag records whether all attempted PIR updates succeeded for the staging item.
      DATA(lv_all_ok)    = abap_true.

*--- Read to GET Index of first data as it is sorted anyway
*--- And then we can add index in loop to control efficiency of nested loop - optimized performance

      lv_tabix = line_index( lt_pir[ supplier               = <ls_stg>-vendor
                                     material               = <ls_stg>-material
                                     purchasingorganization = <ls_stg>-purchaseorganization ] ).

*----- Inner loop: find all PIRs matching this staging record's
*----- supplier + material + purchasing organization combination.
*----- Loop Only if a record is found
      IF lv_tabix > 0.
        LOOP AT lt_pir
        ASSIGNING FIELD-SYMBOL(<ls_pir>)
        FROM lv_tabix.

*----- The moment It does not find this combination - No need to look into other entries
*----- As it is already sorted and there is no chance of an entry being there somewhere after this
          IF <ls_pir>-supplier               <> <ls_stg>-vendor
          OR <ls_pir>-material               <> <ls_stg>-material
          OR <ls_pir>-purchasingorganization <> <ls_stg>-purchaseorganization.
            EXIT.
          ENDIF.

          lv_pir_found = abap_true.

*-------- Validate: currency must match between S/4 and FairMarkit --
*----- If currencies differ, the price comparison is meaningless.
*----- Log the mismatch and skip this PIR (continue to next).
          IF <ls_pir>-currency <> <ls_stg>-currency.
            log_message(
              iv_severity   = if_bali_constants=>c_severity_error
              iv_number     = 005
              iv_variable_1 = CONV #( <ls_pir>-currency )
              iv_variable_2 = CONV #( <ls_stg>-currency ) ).
            lv_all_ok = abap_false.
            CONTINUE.
          ENDIF.

*-------- Validate: Netprice and Priceunit different between S/4 and FairMarkit --
*----- If they are equal, the update is meaningless, price already up to date.
*----- Mark as Success and skip this PIR (continue to next).
          IF <ls_pir>-netpriceamount EQ <ls_stg>-netprice
          AND <ls_pir>-materialpriceunitqty EQ <ls_stg>-priceunit.
            log_message(
               iv_severity   = if_bali_constants=>c_severity_status
               iv_number     = 008
               iv_variable_1 = CONV #( <ls_pir>-purchasinginforecord ) ).
            lv_all_ok = abap_true.
            CONTINUE.
          ENDIF.

*-------- Update PIR with FairMarkit pricing data --------------------
          <ls_pir>-conditionratevalue = <ls_pir>-conditionrateamount = <ls_stg>-netprice.

          lv_all_ok = update_single_pir(
            is_pinfoupdate = VALUE #(
                             general_data-data-purchasinginforecord = <ls_pir>-purchasinginforecord
                             purchasing_org_data = VALUE #( (
                                                   data = VALUE #(
                                                   purchasinginforecord           = <ls_pir>-purchasinginforecord
                                                   purchasinginforecordcategory   = <ls_pir>-purchasinginforecordcategory
                                                   purchasingorganization         = <ls_pir>-purchasingorganization
                                                   plant                          = <ls_pir>-plant
                                                   materialpriceunitqty           = <ls_pir>-materialpriceunitqty
                                                   purchaseorderpriceunit         = <ls_pir>-purchaseorderpriceunit
                                                                 )
                                                   datax = VALUE #(
                                                   purchasinginforecord           = abap_true
                                                   purchasinginforecordcategory   = abap_true
                                                   purchasingorganization         = abap_true
                                                   plant                          = abap_true
                                                   materialpriceunitqty           = abap_true
                                                   purchaseorderpriceunit         = abap_true
                                                                 )
                                                   condition_amount = VALUE #( ( CORRESPONDING #( <ls_pir> ) ) )
                                                          ) )
* The update payload now contains the FairMarkit price that will be sent to the MM Info Record API.
                                    ) ).

* End the loop over matching PIR records for the current staging item.
        ENDLOOP.

*-------- Determine final status for this staging record ---------------
        DATA(lv_status) = COND zscm_fmkt_status(
          WHEN ( lv_pir_found = abap_false OR lv_all_ok = abap_false )
          THEN cv_status_error
          ELSE                                cv_status_success ).

*----- Log if no PIR was found for this item.
        IF lv_pir_found = abap_false.
          log_message(
            iv_severity   = if_bali_constants=>c_severity_error
            iv_number     = 006
            iv_variable_1 = CONV #( |Supplier:{ <ls_stg>-vendor }| )
            iv_variable_2 = CONV #( |Material:{ <ls_stg>-material }| )
            iv_variable_3 = CONV #( |Pur. Org:{ <ls_stg>-purchaseorganization }| ) ).
        ENDIF.

*----- Queue the status update for this record.
*----- All updates are collected and applied in one bulk EML call.
        lt_modifications = VALUE #( (
          %key-pricebookid       = <ls_stg>-pricebookid
          %key-itemid            = <ls_stg>-itemid
          status                 = lv_status
          numberofretries        = <ls_stg>-numberofretries + 1
          %control = VALUE #(
            status           = if_abap_behv=>mk-on
            numberofretries  = if_abap_behv=>mk-on )
        ) ).

*-------- 5. update staging record statuses via EML ------------
*-------- We can not Update one by one as there is a risk of failures
*-------- Also heartbeat needs to be updated so other jobs can check whether in process or dead.
        update_staging_status( lt_modifications ).
        save_log( ).
* End the loop over staging records selected for processing.
      ENDLOOP.
    ENDMETHOD.

    METHOD check_valid_for_retry.
*----------------------------------------------------------------------
* Check whether retry processing can safely include in-progress records.
* The method looks for recently changed retry-job heartbeat entries.
* If no active heartbeat is found in the last five minutes, the method
* allows the retry job to pick records that may have been left by a dead job.
*----------------------------------------------------------------------
      DATA lv_date_time TYPE abp_lastchange_tstmpl.

      TRY.

          rv_yes = abap_false.

          CONVERT DATE sy-datum
                  TIME sy-uzeit
                  INTO TIME STAMP lv_date_time
                  TIME ZONE sy-zonlo.
* Calculate the lower boundary of the heartbeat window by subtracting five minutes from the current timestamp.
          cl_abap_tstmp=>subtractsecs(
            EXPORTING
              tstmp   = lv_date_time
              secs    = 300
            RECEIVING
              r_tstmp = DATA(lv_to_date_time)
          ).

* Look for retry job heartbeat records that were updated during the five-minute monitoring window.
          SELECT @abap_true AS truth
          FROM zi_scm_fmkt_rjobs_pot
          WHERE lastchangedatetime LE @lv_date_time
            AND lastchangedatetime GE @lv_to_date_time
            INTO TABLE @DATA(lt_truth).

            IF sy-subrc <> 0.
* No recent heartbeat means no active retry job was found, so orphaned records can be retried.
              rv_yes = abap_true.
            ENDIF.

          CATCH cx_parameter_invalid_range INTO DATA(lx_parm).
* Keep retry-all disabled if timestamp arithmetic fails because of an invalid range.
            IF lx_parm IS BOUND.
              rv_yes = abap_false.
            ENDIF.
          CATCH cx_parameter_invalid_type INTO DATA(lx_parmt).
* Keep retry-all disabled if timestamp arithmetic fails because of an invalid timestamp type.
            IF lx_parmt IS BOUND.
              rv_yes = abap_false.
            ENDIF.
        ENDTRY.
      ENDMETHOD.

ENDCLASS.