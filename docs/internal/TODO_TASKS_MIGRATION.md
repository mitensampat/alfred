# Tasks Database Migration Guide

## Status: Ready for Testing

### What's Been Done

✅ **TaskItem Model Created**
- Unified model representing both Todos and Commitments
- Enums for TaskType (Todo | Commitment), TaskStatus, Priority, etc.
- Conversion methods: `fromTodoItem()` and `fromCommitment()`
- Location: `Sources/Models/TaskItem.swift` and `Sources/GUI/Models/TaskItem.swift`

✅ **NotionService Extended** 
- New file: `NotionService+Tasks.swift` (both CLI and GUI)
- Methods added:
  - `createTasksDatabase()` - Auto-creates unified database
  - `createTask(TaskItem)` - Creates task with full metadata
  - `queryActiveTasks(type:)` - Query active tasks with filters
  - `updateTaskStatus(notionId:status:)` - Mark tasks as done
  - `findTaskByHash(hash:)` - Duplicate checking
  - `parseTaskFromNotionPage()` - Parse from Notion API response

✅ **Compilation Fixed**
- TaskItem (not Task) to avoid Swift concurrency conflicts
- NotionService.apiKey changed to internal for extension access
- All type references corrected (commitment enums, etc.)
- Both CLI and GUI targets compile successfully

### Next Steps

1. **Create Tasks Database in Notion**
   - Add CLI command: `alfred setup-tasks-db`
   - Or manually call `notionService.createTasksDatabase()`
   - Save database ID to config.json

2. **Update Config**
   ```json
   {
     "notion": {
       "apiKey": "...",
       "tasksDatabase": "NEW_TASKS_DB_ID_HERE",
       "databaseId": "old-todos-db-id",  // Keep for reference
       "commitmentsDatabaseId": "old-commitments-db-id"  // Keep for reference
     }
   }
   ```

3. **Update BriefingOrchestrator**
   - Replace `processWhatsAppTodos()` to create TaskItems instead
   - Replace commitment creation to create TaskItems
   - Update orchestrator initialization to call `notionService.setTasksDatabaseId()`

4. **Update IntentExecutor**
   - Update `formatTodoScanResponse()` to work with TaskItems
   - Update `formatCommitmentScanResponse()` to work with TaskItems
   - Add query methods for tasks

5. **Test End-to-End**
   - Run todo scan → verify TaskItem created in Notion
   - Run commitment scan → verify TaskItem created in Notion  
   - Query active tasks → verify filtering works
   - Mark task as done → verify status update works

### Testing Commands (After Setup)

```bash
# CLI Testing
alfred scan-todos  # Should create TaskItems now
alfred scan-commitments "Contact Name"  # Should create TaskItems

# Web Interface Testing
# Visit http://localhost:8080/index-v2.html
# Try: "Scan for todos"
# Try: "Show my commitments"
# Try: "What tasks are due today?"
```

### Migration Plan

**Option 1: Fresh Start** (Recommended for now)
- Create new Tasks database
- Future scans create TaskItems
- Old databases remain for reference
- No data migration needed

**Option 2: Migrate Existing** (Later)
- Write migration script
- Read all existing Commitments → convert to TaskItems
- Read all existing Todos → convert to TaskItems
- Archive old databases

**Current Status: Option 1 - Ready to create database and test**
