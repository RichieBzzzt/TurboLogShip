

CREATE PROCEDURE [TurboLogShipping].[CustomLogShippingRestore] @RestoreJobName SYSNAME -- we kick off the restore job manually for each backup file to be restored
	,@Database SYSNAME -- name of db that is to be restored on secondary server
AS
/* Custome Restore Log Shipping Stored Procedure
Author: Richie Lee
Date: 28/10/2015
Summary: Recover outstanding log files in NORECOVERY mode until the very last one. Restore this in STANDBY mode.
The use of NORECOVERY mode prevents rolling back uncommitted transactions in between restores. THis will greatly 
reduce the time to restore log files.
*/
SET NOCOUNT ON;

DECLARE @Path NVARCHAR(512);
DECLARE @Count INT;
DECLARE @chkCount INT;
DECLARE @FileTypeLength TINYINT;
DECLARE @RightTrimForBackupInt TINYINT;
DECLARE @FolderDbNameLength TINYINT;
DECLARE @Debug BIT = 0;-- req'd for troubleshooting/testing
DECLARE @maxSessionId INT

SELECT @maxSessionId = MAX(session_id)
FROM [$(msdb)].dbo.syssessions

SELECT @Path = backup_destination_directory
FROM [$(msdb)].dbo.log_shipping_secondary scndry
INNER JOIN [$(msdb)].dbo.log_shipping_secondary_databases db ON db.secondary_id = scndry.secondary_id
WHERE db.secondary_database = @Database;

SELECT @FolderDbNameLength = LEN(last_restored_file) - CHARINDEX('\', REVERSE(last_restored_file)) + 1
FROM [$(msdb)].dbo.log_shipping_secondary_databases db
WHERE db.secondary_database = @Database;

SET @FolderDbNameLength = @FolderDbNameLength + LEN(@database) + 1;

IF @Debug = 1
BEGIN
	SELECT *
	INTO #history
	FROM [$(msdb)].DBO.log_shipping_secondary_databases;--during debug we keep a history of the files restored, their time of restore, and restore settings 
END;

/*
Declare table type and get all the backup files in the copy location.
Create a backupint, which is essentially the backup datetime on the 
file name converted to a big int. This column is used to determine
which files are still required to be restored.
*/
DECLARE @txn txn_tbl;

INSERT @txn (
	subdirectory
	,DEPTH
	,isfile
	)
EXECUTE [$(master)].sys.xp_dirtree @Path
	,1
	,1;

SELECT @FileTypeLength = LEN(REVERSE(SUBSTRING(REVERSE(subdirectory), 1, CHARINDEX('.', REVERSE(subdirectory)))))
FROM @txn;

SET @RightTrimForBackupInt = LEN(@database) + @FileTypeLength + 1;--.trn and trailing undercarriage

UPDATE @txn
SET BackupInt = CAST(RIGHT(LEFT(subdirectory, LEN(subdirectory) - @FileTypeLength), LEN(subdirectory) - @RightTrimForBackupInt) AS BIGINT);

/*
Get total count of the files that are yet to be restored.
To achive this, we get all files that have a BackupInt value that is 
greater than the "BackupInt" of the last restored file for the database
*/
SELECT @Count = COUNT(*)
FROM @txn t
WHERE t.BackupInt > (
		SELECT CAST(RIGHT(LEFT(last_restored_file, LEN(last_restored_file) - @FileTypeLength), LEN(last_restored_file) - (@FolderDbNameLength + @FileTypeLength)) AS BIGINT)
		FROM [$(msdb)].dbo.log_shipping_secondary_databases
		WHERE secondary_database = @Database
		);

IF @Debug = 1
BEGIN
	SELECT *
	FROM @txn t
	WHERE t.BackupInt > (
			SELECT CAST(RIGHT(LEFT(last_restored_file, LEN(last_restored_file) - @FileTypeLength), LEN(last_restored_file) - (@FolderDbNameLength + @FileTypeLength)) AS BIGINT)
			FROM [$(msdb)].dbo.log_shipping_secondary_databases
			WHERE secondary_database = @Database
			);

	SELECT 'Initial count:' + CAST(@Count AS NVARCHAR(5));
END;

/*
if there is more than one file to restore we alter the restore mode to NO RECOVERY
and only restore one file at a time. Then we loop through the count and execute the restore job.
This means the databse will be in "restoring" mode duringthis time and no transaction undo file (tuf)
needs to be created. Where we have a large number of backups that were backed up during a time 
where there was lots of log activity (index rebuilds, overnight jobs) this will significantly
speed up the process of restoring the log file.

There is an additional check inside this lop to see if any files have been copied over from the 
primary whilst the restores were taking place and updates the count value accordingly. The reason for this 
is so because when we get to the end of this loop, the count of outstanding files to be restored is 
correct (ie count is 1 and number of files to restore is actually 1.
*/
WHILE @Count > 1
BEGIN
	EXECUTE [$(master)].sys.sp_change_log_shipping_secondary_database @secondary_database = @Database
		,@disconnect_users = 1 -- disconnect users 
		,@restore_mode = 0 -- restore log with NORECOVERY
		,@restore_all = 0;-- stops after one file has been restored

	/*
When the restore job is kicked off, the script does not wait for the job to complete before it moves on.
So the WHILE statement below will check to see if the job is running. IF the job is running it will wait
for a pre-determined length of time before checking again. It will continue to do this until the job is not
running and will kick off the job to restore again.
*/
	WHILE (
			SELECT 1
			FROM [$(msdb)].dbo.sysjobs_view job
			INNER JOIN [$(msdb)].dbo.sysjobactivity activity ON job.job_id = activity.job_id
			WHERE activity.run_requested_date IS NOT NULL
				AND activity.stop_execution_date IS NULL
				AND job.name = @RestoreJobName
				AND activity.session_id = @maxSessionId
			) = 1
	BEGIN
		WAITFOR DELAY '00:00:00:100';
	END;

	EXECUTE [$(msdb)].dbo.sp_start_job @RestoreJobName;

/* now we need ot wait agin until the job has completed.
This is because we check for any files that have been 
copied over while we're in the @COUNT loop. Thi is explained
fully below*/

	WHILE (
			SELECT 1
			FROM [$(msdb)].dbo.sysjobs_view job
			INNER JOIN [$(msdb)].dbo.sysjobactivity activity ON job.job_id = activity.job_id
			WHERE activity.run_requested_date IS NOT NULL
				AND activity.stop_execution_date IS NULL
				AND job.name = @RestoreJobName
				AND activity.session_id = @maxSessionId
			) = 1
	BEGIN
		WAITFOR DELAY '00:00:00:100';
	END;

	IF @Debug = 1
	BEGIN
		INSERT INTO #history
		SELECT *
		FROM [$(msdb)].dbo.log_shipping_secondary_databases;

		SELECT *
		FROM [$(msdb)].dbo.log_shipping_secondary_databases;
	END;

	IF @Debug = 1
	BEGIN
		SELECT 'loop count:' + CAST(@Count AS NVARCHAR(5));
	END;

	/*
	Begin of check for any files that have been copied over since the last restore.
	Create a table variable from type table and get all files in the copy directory
	
	There is a lot of code re-use from above. Ideally, all this would be in a separate stored procedure,
	however because we are running and INSERT...EXEC command here we cannot nest the call. Because we are 
	relying on an extended system sproc to get the files, there is not much we can do other than re-use code.
	*/
	DECLARE @chk txn_tbl;

	INSERT @chk (
		subdirectory
		,DEPTH
		,isfile
		)
	EXECUTE [$(master)].sys.xp_dirtree @Path
		,1
		,1;

	UPDATE @chk
	SET BackupInt = CAST(RIGHT(LEFT(subdirectory, LEN(subdirectory) - @FileTypeLength), LEN(subdirectory) - @RightTrimForBackupInt) AS BIGINT);

	INSERT INTO @txn (
		subdirectory
		,DEPTH
		,isfile
		,BackupInt
		)
	SELECT subdirectory
		,DEPTH
		,isfile
		,BackupInt
	FROM @chk
	WHERE BackupInt NOT IN (
			SELECT BackupInt
			FROM @txn
			);

	SELECT @Count = COUNT(*) --new update for count
	FROM @txn t
	WHERE t.BackupInt > (
			SELECT CAST(RIGHT(LEFT(last_restored_file, LEN(last_restored_file) - @FileTypeLength), LEN(last_restored_file) - (@FolderDbNameLength + @FileTypeLength)) AS BIGINT)
			FROM [$(msdb)].dbo.log_shipping_secondary_databases
			WHERE secondary_database = @Database
			);

	IF @Debug = 1
	BEGIN
		SELECT *
		FROM @txn t
		WHERE t.BackupInt > (
				SELECT CAST(RIGHT(LEFT(last_restored_file, LEN(last_restored_file) - @FileTypeLength), LEN(last_restored_file) - (@FolderDbNameLength + @FileTypeLength)) AS BIGINT)
				FROM [$(msdb)].dbo.log_shipping_secondary_databases
				WHERE secondary_database = @Database
				);
	END;

	/*
	end check for additionally copied files
	*/
	IF @Debug = 1
	BEGIN
		SELECT 'post-check count:' + CAST(@Count AS NVARCHAR(5));
	END;
END;

/*
	Now we come to the final restore. Ther will only now be one file left to restore. So we can alter the 
	restore method back to STANDBY and restore all logs. So now at the end of the process the database will be INSERT 
	Standby/Read only mode.
	*/
WHILE (
		SELECT 1
			FROM [$(msdb)].dbo.sysjobs_view job
			INNER JOIN [$(msdb)].dbo.sysjobactivity activity ON job.job_id = activity.job_id
			WHERE activity.run_requested_date IS NOT NULL
				AND activity.stop_execution_date IS NULL
				AND job.name = @RestoreJobName
				AND activity.session_id = @maxSessionId
		) = 1
BEGIN
	WAITFOR DELAY '00:00:00:100';
END;

EXECUTE [$(master)].sys.sp_change_log_shipping_secondary_database @secondary_database = @Database
	,@disconnect_users = 1 -- disconnect users
	,@restore_mode = 1 -- restore log with STANDBY 
	,@restore_all = 1;-- restore all logs 

EXECUTE [$(msdb)].dbo.sp_start_job @RestoreJobName;

WHILE (
		SELECT 1
			FROM [$(msdb)].dbo.sysjobs_view job
			INNER JOIN [$(msdb)].dbo.sysjobactivity activity ON job.job_id = activity.job_id
			WHERE activity.run_requested_date IS NOT NULL
				AND activity.stop_execution_date IS NULL
				AND job.name = @RestoreJobName
				AND activity.session_id = @maxSessionId
		) = 1
BEGIN
	WAITFOR DELAY '00:00:00:100';
END;

IF @Debug = 1
BEGIN
	INSERT INTO #history
	SELECT *
	FROM [$(msdb)].DBO.log_shipping_secondary_databases;

	SELECT *
	FROM [$(msdb)].DBO.log_shipping_secondary_databases;
END;

SET NOCOUNT OFF;

IF @Debug = 1
BEGIN
	SELECT *
	FROM #history;

	DROP TABLE #history;
END;

