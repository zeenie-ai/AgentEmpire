-- Whether a task or agent rule made from the approval covers only its exact words (1) or also
-- further arguments that stay inside the work folder (0). NULL for approvals stored before it.
ALTER TABLE approvals ADD COLUMN rule_exact INTEGER;
