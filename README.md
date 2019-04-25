# TurboLogShip

Despite the development of AlwaysOn in recent releases of SQL Server, log shipping is still a great way to set up a copy of databases to be used for reporting. One of the main reasons it is great is because, unlike AlwaysOn, it is available in less expensive editions like Standard and Web from SQL Server 2008 onwards. Sure, in 2016 AlwaysOn will be available in Standard, but in a greatly deprecated form, and you cannot read from the secondary. So it will be good for DR, but not for reporting (as an aside it still might be easier to set up log shipping for DR than AlwaysOn Basic because you need to setup a failover cluster. Read through the “how to set up Standard Edition Availability Groups” here.) However you do need to be careful though when setting up log shipping across different editions of SQL Server: whilst you can log ship between Enterprise to Standard/Web, if the database uses any Enterprise features then you’ll need to log ship to an Enterprise edition of SQL Server. And because you’ll be using the database for reporting, you’ll need to get it licensed.

Let’s take a brief overview of how log shipping works. The database being log shipped from is known as the “primary”, and the log shipped database is called the “secondary”. Log shipping requires a complete copy of the database on the secondary server, so unlike replication, it is not possible to be selective on which database objects we want to copy over. Similarly to replication though, log shipping works by using a variety of SQL Agent jobs to execute processes. There is a Backup job, Copy Job, Restore Job, and an optional Alert job. The first three jobs use an application called logship.exe to run. It takes a set of commands to run the backup, copy and restore. There is full documentation on Books Online. The Alert job runs a system stored procedure called sys.sp_check_log_shipping_monitor_alert in the master database. Let’s dig into these jobs a bit deeper one by one:

Backup Job: runs t-log backups of the primary database. Simple enough, however this job will now have to replace whatever log backup you are running on the database, because any log backups taken that aren't ad-hoc (COPY ONLY) have to be restored to the secondary, otherwise you'll break the log chain. Whilst this may seem OK on the surface, if you're on older versions of SQL Server you may need to check if backup compression is a feature supported in your edition. This is less of a problem on SQL Server 2012 and SQL Server 2014 (Enterprise, Standard and Business Intelligence) but in both 2008 (Enterprise only) and 2008 R2 (Datacenter, Enterprise, or Standard) backup compression is more of an exclusive feature. So your log backups may be slower and larger than before. Log shipping also needs the names of the files to be in a very specific format, so any external log backup process may not work with log shipping. I really could go on about backups in a completely different post...
Copy Job: copies the backup files from the primary server backup location to the secondary server. One thing to note is that when setting up this job for log shipping, you specify the threshold for old log files to be deleted from the secondary server. However the task to delete the old files is part of the restore job post-restore of any log files (you can verify this behaviour yourself by looking at the job history of the restore job.)
Restore Job: Well, you've probably already guessed what this job does! This job takes the restore settings of the database and restores the log files accordingly. And by restore settings I mean whether the database is RESTORE with STANDBY or RESTORE with NORECOVERY, whether all the log files are to be restored, and whether to disconnect users when initializing the restore. Because we're setting up a report server, we'd want to disconnect users, as we'd probably be waiting forever for users to be disconnected. This is a disadvantage of using a log shipped database for reporting, but really it is up to you to determine when the log can be restored and the needs of the report run times before deciding that a read-only log shipped database is the solution to your reporting needs (and this is really crucial). This job will also delete any copied log backups that exceed the expiry threshold.
Alert Job: Will send emails when backup/restore thresholds have been exceeded. These thresholds are set when log shipping is initialized. I would recommend activating the alert job when you initialize log shipping, as going back and setting up afterwards is apparently difficult (I've not done it so cannot determine how true this is.) However I would argue that you'd have to have a pretty good reason not to set up the alerts regarding the last log backups and restores, unless your preferred monitoring software allows you to customise the alert thresholds for last backup/restores. And even if it does, the cost of licensing a server to use monitoring software will always cost more than the built in monitoring in log shipping. But by no means is the alerting complete, and you'll want to write some more monitoring jobs yourself. One such job might be to monitor the duration of a job and email if a threshold is met. A sample of such a script is below:

```sql
USE [master]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

--job name you want to monitor
--percentage difference threshold
--db mail settings
CREATE PROCEDURE [dbo].[AlertOnLongRunningJobs] (
@jobName NVARCHAR(100)
,@pct DECIMAL(10, 2)
,@db_mail_profile NVARCHAR(100)
,@db_mail_recipients NVARCHAR(100)
)
AS
SET NOCOUNT ON

--get email address for operator

SELECT @db_mail_recipients = email_address from msdb.dbo.sysoperators where name = @db_mail_recipients

--the percentage increase between the average run time and the runtime of the job running now
DECLARE @increase DECIMAL(10, 2)
DECLARE @runtime DECIMAL(10, 2)
DECLARE @avgRunTime DECIMAL(10, 2)
--db mail settings
DECLARE @db_mail_body NVARCHAR(512)
DECLARE @db_mail_subject NVARCHAR(256)

CREATE TABLE #runningJobs (
running_job_id UNIQUEIDENTIFIER
,running_job_name NVARCHAR(100)
,runtime VARCHAR(8)
)

CREATE TABLE #jobHistory (
job_id UNIQUEIDENTIFIER
,job_name NVARCHAR(100)
,avgRunTime VARCHAR(8)
)

--check if job is running now
INSERT INTO #runningJobs
SELECT j.job_id
,j.NAME AS job_name
,CONVERT(VARCHAR, (GETDATE() - ja.start_execution_date), 108)
FROM msdb.dbo.sysjobactivity ja
LEFT JOIN msdb.dbo.sysjobhistory jh ON ja.job_history_id = jh.instance_id
INNER JOIN msdb.dbo.sysjobs j ON ja.job_id = j.job_id
INNER JOIN msdb.dbo.sysjobsteps js ON ja.job_id = js.job_id
AND ISNULL(ja.last_executed_step_id, 0) + 1 = js.step_id
WHERE ja.session_id = (
SELECT TOP 1 session_id
FROM msdb.dbo.syssessions
ORDER BY agent_start_date DESC
)
AND start_execution_date IS NOT NULL
AND stop_execution_date IS NULL
AND j.NAME = @jobName

--if the job is running now, then we execute rest of query, or we just stop here.
IF EXISTS (
SELECT 1
FROM #runningJobs
)
INSERT INTO #jobHistory
SELECT jobid = job_id
,job_name = NAME
,avg_hhmmss = CONVERT(CHAR(8), DATEADD(second, rd, 0), 108)
FROM (
SELECT j.NAME
,j.job_id
,COUNT(*) AS NumberOfRuns
,rd = AVG(DATEDIFF(SECOND, 0, STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(6), run_duration), 6), 5, 0, ':'), 3, 0, ':')))
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs AS j ON h.job_id = j.job_id
WHERE h.step_id = 0
AND j.NAME = @jobName
GROUP BY j.NAME
,j.job_id
) AS rs
ORDER BY job_name

--get run time of current job and average runtime
SELECT @runtime = DATEDIFF(second, 0, runtime)
FROM #runningJobs

SELECT @avgRunTime = DATEDIFF(SECOND, 0, avgRunTime)
FROM #jobHistory

--set the percentage increase of the current run of job.
--if it is greater than percentage threshold then return job name.
SET @increase = @runtime - @avgRunTime
SET @increase = (@increase / @avgRunTime) * 100

IF (@increase &amp;gt; @pct)
BEGIN
SET @db_mail_subject = 'Long Running SQL Agent Job on ' + (
SELECT @@SERVERNAME
)
SET @db_mail_body = 'The job ' + @jobName + ' has been running for ' + (
SELECT runtime
FROM #runningJobs
) + ' (hhmmss). The avergage duration for this job is ' + (
SELECT avgRunTime
FROM #jobHistory
) + '(hhmmss).
This is a ' + CAST(@increase AS NVARCHAR(12)) + '% increase. Please investigate.'

EXEC msdb.dbo.sp_send_dbmail @profile_name = @db_mail_profile
,@recipients = @db_mail_recipients
,@body = @db_mail_body
,@subject = @db_mail_subject;

DROP TABLE #runningJobs

DROP TABLE #jobHistory
END

GO
```

You're all probably aware that you can also set jobs to email an operator if they fail. Whilst this can be useful, the frequency of the log shipping jobs will probably be set at several times an hour. And I really am not a fan of bombarding peoples inboxes with emails. Obviously if a log backup fails you want to get right on that and fix it, but possibly you could afford to have the reporting server fail a couple of restores before someone takes a look at it. Or you may wish to have a summary of the failed jobs over a 24 hour period sent out to first level support for them to escalate. So a more pragmatic solution would be to create a job that would check if any of the jobs have failed within a set time frame (say, below the restore threshold but higher than the frequency of the jobs failing.) An example of this sort of alert that emails if any jobs have failed in the past day is below.

```sql
USE [master]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[AlertOnFailedLogShippedJobs] (
@DaysPast INT
,@db_mail_profile NVARCHAR(100)
,@db_mail_recipients NVARCHAR(100)
)
AS
SET NOCOUNT ON;

DECLARE @Value [varchar] (2048)
,@JobName [varchar] (2048)
,@PreviousDate [datetime]
,@Year [varchar] (4)
,@Month [varchar] (2)
,@MonthPre [varchar] (2)
,@Day [varchar] (2)
,@DayPre [varchar] (2)
,@FinalDate [int]
-- Declaring Table variable
DECLARE @FailedJobs TABLE (
[JobName] [varchar](200)
,[RunDate] NVARCHAR(20)
,[RunTime] VARCHAR(16)
)
--db mail settings
DECLARE @db_mail_body NVARCHAR(MAX)
DECLARE @db_mail_subject NVARCHAR(128)

-- Initialize Variables
SET @PreviousDate = DATEADD(DAY, - @DaysPast, GETDATE())
SET @Year = DATEPART(yyyy, @PreviousDate)

SELECT @MonthPre = CONVERT([varchar](2), DATEPART(mm, @PreviousDate))

SELECT @Month = RIGHT(CONVERT([varchar], (@MonthPre + 1000000000)), 2)

SELECT @DayPre = CONVERT([varchar](2), DATEPART(dd, @PreviousDate))

SELECT @Day = RIGHT(CONVERT([varchar], (@DayPre + 1000000000)), 2)

SET @FinalDate = CAST(@Year + @Month + @Day AS [int])

SELECT @db_mail_recipients = email_address
FROM msdb.dbo.sysoperators
WHERE NAME = @db_mail_recipients

-- Final Logic
INSERT INTO @FailedJobs
SELECT DISTINCT j.[name] AS JobName
,STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(8), h.run_date), 8), 7, 0, '-'), 5, 0, '-') AS RunDate
,STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(6), h.run_time), 6), 5, 0, ':'), 3, 0, ':') AS RunTime
FROM [msdb].[dbo].[sysjobhistory] h
INNER JOIN [msdb].[dbo].[sysjobs] j ON h.[job_id] = j.[job_id]
INNER JOIN [msdb].[dbo].[sysjobsteps] s ON j.[job_id] = s.[job_id]
AND h.[step_id] = s.[step_id]
WHERE h.[run_status] = 0
AND h.[run_date] &gt; @FinalDate
AND j.[name] LIKE 'LS%'

--remove the above line for all jobs
IF @@ROWCOUNT &gt; 0
BEGIN
DECLARE @lastCopiedFile NVARCHAR(100)
,@LastCopiedDate DATETIME
,@LastRestoreFile NVARCHAR(100)
,@LastRestoredDate DATETIME

SELECT @lastCopiedFile = last_copied_file
,@LastCopiedDate = last_copied_date
,@LastRestoreFile = last_restored_file
,@LastRestoredDate = last_restored_date
FROM msdb.dbo.log_shipping_monitor_secondary

SET @db_mail_subject = 'Failed Log Shipping Job on ' + (
SELECT @@SERVERNAME
)
SET @db_mail_body = N'

&lt;H1&gt;Failed Log Shipping Job&lt;/H1&gt;


' + N'

&lt;h3&gt;The following Log Shipping jobs have failed in the past 24 hours&lt;/h3&gt;


' + '

The last copied file was ' + @lastCopiedFile + ' at ' + CAST(@LastCopiedDate AS NVARCHAR(20)) + '. The last restored file was ' + @LastRestoreFile + ' at ' + CAST(@LastRestoredDate AS NVARCHAR(20)) + '.' + CHAR(10) + CHAR(13) + N'

&lt;table border=&quot;1&quot;&gt;' + N'

&lt;tr&gt;

&lt;th&gt;JobName&lt;/th&gt;


' + N'

&lt;th&gt;RunDate&lt;/th&gt;


' + N'

&lt;th&gt;RunTime&lt;/th&gt;


' + '&lt;/tr&gt;


' + cast((
SELECT td = FJ.JobName
,''
,td = FJ.RunDate
,''
,td = FJ.RunTime
,''
FROM @FailedJobs FJ
FOR XML path('tr')
,type
) AS NVARCHAR(max)) + N'&lt;/table&gt;


' + CHAR(10) + CHAR(13) + '

Please investigate.'

EXEC msdb.dbo.sp_send_dbmail @profile_name = @db_mail_profile
,@recipients = @db_mail_recipients
,@body = @db_mail_body
,@body_format = 'HTML'
,@subject = @db_mail_subject
END
GO
```

One of the limitations to using a read-only log shipped database for reports is that the data is only up to the latest log restore that occurred on the database. And during a restore the database will not only kick users off but also be unavailable during a log restore. So again this comes back to the point of understanding these limitations to help make a decision on whether a read-only log shipped database is the way to go. It might even be simpler to restore a database from an overnight backup if the data can be a day old for reporting. (As an aside, the benefit to this point in time restore lagging somewhat behind your primary database is that that you can restore data back to the primary: say someone has dropped a table or deleted an important record, and because we have the read-only secondary we are able to retrieve it before the error is copied over. The downside is that, this does involve finding out about the issue before the affected log is restored, but it can happen.)

Another limitation is that using the RESTORE with STANDBY mode is far slower to restore than the NORECOVERY mode. This is because the read-only database needs to be transactionally consistent to report from, so any uncommitted transactions need to be undone during the STANDBY restore. So if you have a large log backup that is pretty much uncommitted transactions (think index rebuild of a capacious table) then all the pages of that table will need to be written to a transaction undo file (.tuf). Come the next restore this undo file will have to be re-written back to the database before the next restore can be started. So lets imagine you have an hour-long ETL process overnight, and you take 4 backups in that time, then the undo/redo process will have to be repeated several times, taking a very long time: I once saw an log file being restored that was 6GB of uncommitted transactions, and the tuf file created at the end of this was a massive 28GB! This restore took 2 hours to complete! And the reason why the tuf file was so much bigger than the log file was because it has to copy all the pages affected to the tuf file.

So again, understanding these limitations will help in deciding whether a read-only log-shipped database really is any good for reporting from or not. However there are ways to reduce the time of the restore job, and you can apply some or all of them and test how effective they are:

Reduce the number of backups taken (assuming your RPO permits changes): Theoretically, the less backups you take means there's less backups to restore, and so less tuf files to create. This can work, particularly if your backups span over a long running uncommitted transaction. However you do have to consider your RPO: you will lose more data with longer times taken between log backups. This is however a way to reduce restore times. But I'm not necessarily advocating this as a method to adopt....
Move delete job out of restore job: If the backup files are large, it may take some time to delete these files from the backup folder. As this task runs as part of the restore job, you could create a delete job yourself to run during a time that the restore job is not running (even when the database is in read-only mode, you won't be affecting the database as the delete job will just access the file system.) Then re-configure the log shipping copy job to delete files at a very high threshold so that the restore job will never have to delete files. A sample of a custom delete job is below: this will delete any files that are 12 hours older then the last restored log file on the secondary server. Create a custom delete job on the server and add this as a step and schedule to run whenever you need it to. You still have to be careful about how many files you keep in this location though, as the restore job still has to scan the contents of the folder. Keep in mind that this is only a copy of the files to be restored, not the actual backup files themselves (unless you are restoring from the original backup location). So you can keep the number of files here at a relatively low number by keeping the threshold small.

```sql
DECLARE @path NVARCHAR(50) = 'M:\LS_Backups'
DECLARE @LastRestoreFileDate DATETIME

SELECT @LastRestoreFileDate = CAST(STUFF(STUFF(STUFF(STUFF(STUFF(RIGHT(LEFT(last_restored_file, LEN(last_restored_file) - 4), LEN(last_restored_file) - 45), 11, 0, ':'), 14, 0, ':'), 5, 0, '-'), 8, 0, '-'), 11, 0, ' ') AS DATETIME)
FROM msdb.dbo.log_shipping_secondary_databases

DECLARE @DeleteDate DATETIME = DATEADD(HOUR, - 8, @LastRestoreFileDate)

EXEC master.sys.xp_delete_file 0
,@path
,'trn'
,@DeleteDate
,0;
```

Restore files under NORECOVERY, then switch to STANDBY: as mentioned, you have two restore choices: NORECOVERY and STANDBY. Both these choices will allow further log restores, but STANDBY is the option to choose if you want the database to be read-only. NORECOVERY leaves the database in a transactionally inconsistent state: it does not roll back uncommitted transactions into a tuf file. So it is possible to restore the log files in NORECOVERY mode, and then restore a final log with the STANDBY option to enable the database to be read-only (it is pretty neat that you can switch between STANDBY and NORECOVERY in this way.) Sadly, this option is not an out-the-box operation, and so requires writing a custom job to restore the log files. I’ve read online a few methods to achieve this, and I have written my own custom restore process. The steps that it follows are:

Get all files in the “copy to” location using master.sys.xp_dirtree

Compare these files to the last restored file in the msdb.dbo.log_shipping_secondary_databases table (and create a count of the total files)

Loop through the count for each file

Use the master.sys.sp_change_log_shipping_secondary_database sproc to alter the recovery mode to NORECOVERY and to only restore one file at a time

Start the default restore job using msdb.dbo.sp_start_job

Check if any other files have been copied over, and add them to the count

Continue restoring one file at a time in NORECOVERY mode until there is one file left (COUNT=1)

Use the master.sys.sp_change_log_shipping_secondary_database sproc to alter recovery mode back to STANDBY and to restore all files (just to be sure)

Start the default restore job using msdb.dbo.sp_start_job.


This required quite a bit of testing, and thinking to ensure that the process ran smoothly. Yet it works extremely well and the check for any additionally copied files ensures that at the end of the process there will only be one file to restore and therefore only one tuf file to create. It also makes sense to use the default restore job to actually restore the log file itself: because the default job executes the application logship.exe, it will keep all internal changes valid and consistent. Also, because I’d like to be the first person to know if the database is in the incorrect state after the custom restore job, I created a step that will check if the log-shipped database is in a read only mode or not, and if it is not to email me. It should never happen, but it’s always best to be safe than sorry! A sample of this kind of check is below:

```sql

USE [msdb]
GO

/****** Object:StoredProcedure [dbo].[MonitorCustomLogShippingRestore]Script Date: 11/09/2015 12:34:37 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[MonitorCustomLogShippingRestore]

@restoreJobName SYSNAME 
	,@Database SYSNAME
	,@db_mail_profile NVARCHAR(100)
	,@db_mail_recipients NVARCHAR(100)
AS

--db mail settings
DECLARE @db_mail_body NVARCHAR(MAX)
DECLARE @db_mail_subject NVARCHAR(128)
DECLARE @DBState NVARCHAR (20)
DECLARE @DBUserAccessState NVARCHAR (20)
DECLARE @DBIsInStandby NVARCHAR (32)
SELECT @db_mail_recipients = email_address from msdb.dbo.sysoperators where name = @db_mail_recipients 

SELECT 1 
FROM [master].[sys].[databases] 
WHERE name = @Database
AND is_read_only = 1
IF @@ROWCOUNT = 0
BEGIN
	SET @db_mail_subject = 'Database '+@Database+' Not In Correct State on Server' + (
			SELECT @@SERVERNAME
			)
SET @db_mail_body =N'&lt;h3&gt;The databse '+@Database+' is in the incorrect state. The job '+@restoreJobName+' has completed restoring all backup files.
The database '+@database+' is '+@DBState+'. The restriction accces is '+@DBUserAccessState+'. The database '+@database+' is '+@DBIsInStandby+'.
To resolve, run another restore using the STANDBY option, and investigate the root cause of the issue.&lt;/h3&gt;' 

	EXEC msdb.dbo.sp_send_dbmail @profile_name = @db_mail_profile
		,@recipients = @db_mail_recipients
		,@body = @db_mail_body
		,@body_format = 'HTML'
		,@subject = @db_mail_subject

END

GO
```

However, even with a custom job you may still experience large delays: if the restore time is only scheduled to run between 5AM to 8AM, and the last restored file still has a large number of uncommitted transactions, it will still take a long time to restore this final log file. So you need to look at the schedules of jobs running on the server and what data is needed for reports to make sure you are not left with a large .tuf file at the end of the process.

Outside of using the database as a reporting database, some people may think that they can run CHECKDB on a log shipped database. Unfortunately this is not the case, and you will either have to run on the production server or a BACKUP/RESTORE of the primary database. You also need to be careful about which version you are restoring to: you cannot RESTORE with STANDBY to a later version of SQL Server. This happened to a colleague of mine when he was trying to set up log shipping, a time consuming mistake that is probably made quite frequently, especially as it is possible to log ship to a later build using the NORECOVERY option. Another popular myth is that running the primary database in the bulk logged recovery model will make the backup files smaller. This is not true.

Ultimately, using a log shipped copy of a database for reporting purposes is perfectly feasible, providing you know the limitations of the technology and if it will fit into your needs. Despite these limitations, it is by no means a bad technology: in fact logshipping really is a good option in the right circumstance, it might just not be right for your reporting needs. You'll never have your secondary database available for reporting 24/7, and unless your database is very small with relatively low activity occurring, you'll probably have to manage restore times with a custom restore job. So you'll need to manage the expectations of the users when implementing a read-only copy of the database. But don't let that put you off: in the right situation, using a log-shipped read-only database for your reporting needs is quick and straightforward to set up and is very robust.
