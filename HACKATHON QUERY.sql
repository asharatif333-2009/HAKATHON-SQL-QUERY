--Q01: Month-end headcount by plant and department, for all six months
SELECT 
    EOMONTH(eh.effective_from) AS month_end_date,
    d.dept_name AS department_name,
    COUNT(DISTINCT eh.emp_id) AS headcount
FROM employment_history eh
JOIN departments d ON eh.dept_id = d.dept_id
GROUP BY EOMONTH(eh.effective_from), d.dept_name
ORDER BY month_end_date, d.dept_name;

--Q02: Monthly attrition rate by department (separations + average headcount)
SELECT 
    d.dept_name AS department_name,
    FORMAT(eh.effective_from, 'yyyy-MM') AS pay_month,
    COUNT(CASE WHEN eh.change_reason = 'Separation' THEN 1 END) AS separations,
    COUNT(DISTINCT eh.emp_id) AS active_headcount
FROM employment_history eh
JOIN departments d ON eh.dept_id = d.dept_id
GROUP BY d.dept_name, FORMAT(eh.effective_from, 'yyyy-MM');

--Q03: Absenteeism rate by plant and month, excluding approved leave
SELECT 
    FORMAT(a.shift_date, 'yyyy-MM') AS month_str,
    d.dept_name AS department_name,
    CAST(SUM(CASE WHEN a.status = 'Absent' THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) AS absenteeism_rate
FROM attendance_daily a
JOIN employees e ON a.emp_id = e.emp_id
JOIN employment_history eh ON e.emp_id = eh.emp_id 
    AND a.shift_date BETWEEN eh.effective_from AND ISNULL(eh.effective_to, '9999-12-31')
JOIN departments d ON eh.dept_id = d.dept_id
GROUP BY FORMAT(a.shift_date, 'yyyy-MM'), d.dept_name;

--Q04: The 10 employees with the most late arrivals, and their department
SELECT TOP 10
    e.emp_id,
    d.dept_name AS department_name,
    COUNT(*) AS late_count
FROM attendance_daily a
JOIN employees e ON a.emp_id = e.emp_id
JOIN employment_history eh ON e.emp_id = eh.emp_id 
    AND a.shift_date BETWEEN eh.effective_from AND ISNULL(eh.effective_to, '9999-12-31')
JOIN departments d ON eh.dept_id = d.dept_id
WHERE a.late_minutes > 10
GROUP BY e.emp_id, d.dept_name
ORDER BY late_count DESC;

--Q05: Overtime hours computed from punches vs approved vs paid, by department and month
SELECT 
    FORMAT(TRY_CAST(a.shift_date AS DATE), 'yyyy-MM') AS month_str,
    d.dept_name AS department_name,
    SUM(a.overtime_hours) AS computed_ot,
    SUM(ISNULL(ot.approved_hours, 0)) AS approved_ot,
    SUM(CASE WHEN pl.component = 'Overtime Pay' THEN pl.amount ELSE 0 END) AS paid_ot_amount
FROM attendance_daily a
JOIN employees e ON a.emp_id = e.emp_id
JOIN employment_history eh ON e.emp_id = eh.emp_id 
    AND TRY_CAST(a.shift_date AS DATE) BETWEEN eh.effective_from AND ISNULL(eh.effective_to, '9999-12-31')
JOIN departments d ON eh.dept_id = d.dept_id
LEFT JOIN overtime_requests ot ON a.emp_id = ot.emp_id AND TRY_CAST(a.shift_date AS DATE) = TRY_CAST(ot.ot_date AS DATE)
LEFT JOIN payroll_lines pl ON e.emp_id = pl.emp_id AND FORMAT(TRY_CAST(a.shift_date AS DATE), 'yyyy-MM') = FORMAT(TRY_CAST(pl.payroll_month AS DATE), 'yyyy-MM')
WHERE TRY_CAST(a.shift_date AS DATE) IS NOT NULL
GROUP BY FORMAT(TRY_CAST(a.shift_date AS DATE), 'yyyy-MM'), d.dept_name;

--Q06: Departments where paid overtime exceeds computed overtime by more than 15%
WITH OtComparison AS (
    SELECT 
        d.dept_name AS department_name,
        SUM(a.overtime_hours) AS computed_ot_hrs,
        SUM(CASE WHEN pl.component = 'Overtime Pay' THEN pl.amount ELSE 0 END) AS paid_amount
    FROM attendance_daily a
    JOIN employees e ON a.emp_id = e.emp_id
    JOIN employment_history eh ON e.emp_id = eh.emp_id 
        AND TRY_CAST(a.shift_date AS DATE) BETWEEN eh.effective_from AND ISNULL(eh.effective_to, '9999-12-31')
    JOIN departments d ON eh.dept_id = d.dept_id
    LEFT JOIN payroll_lines pl ON e.emp_id = pl.emp_id AND FORMAT(TRY_CAST(a.shift_date AS DATE), 'yyyy-MM') = FORMAT(TRY_CAST(pl.payroll_month AS DATE), 'yyyy-MM')
    GROUP BY d.dept_name
)
SELECT * 
FROM OtComparison;


--Q07: Employees paid in a month with zero attendance in that month
SELECT DISTINCT 
    pl.emp_id,
    pl.payroll_month
FROM payroll_lines pl
WHERE NOT EXISTS (
    SELECT 1 FROM attendance_daily a
    WHERE a.emp_id = pl.emp_id
      AND FORMAT(TRY_CAST(a.shift_date AS DATE), 'yyyy-MM') = FORMAT(TRY_CAST(pl.payroll_month AS DATE), 'yyyy-MM')
      AND a.status = 'Present'
);


--Q08: Employees still receiving pay after their separation date
SELECT DISTINCT 
    pl.emp_id,
    pl.payroll_month,
    e.separation_date
FROM payroll_lines pl
JOIN employees e ON pl.emp_id = e.emp_id
WHERE e.separation_date IS NOT NULL
  AND TRY_CAST(pl.payroll_month AS DATE) > TRY_CAST(e.separation_date AS DATE);


 --Q09: Monthly payroll cost analysis by department and cost per employee with MoM comparison
WITH DeptPayroll AS (
    SELECT 
        LEFT(CAST(pl.payroll_month AS VARCHAR(50)), 7) AS pay_month,
        d.dept_name AS department_name,
        SUM(pl.amount) AS total_cost,
        COUNT(DISTINCT pl.emp_id) AS emp_count
    FROM payroll_lines pl
    JOIN employees e ON pl.emp_id = e.emp_id
    JOIN employment_history eh ON e.emp_id = eh.emp_id 
    JOIN departments d ON eh.dept_id = d.dept_id
    GROUP BY LEFT(CAST(pl.payroll_month AS VARCHAR(50)), 7), d.dept_name
)
SELECT 
    pay_month,
    department_name,
    total_cost / NULLIF(emp_count, 0) AS cost_per_emp,
    LAG(total_cost / NULLIF(emp_count, 0)) OVER (PARTITION BY department_name ORDER BY pay_month) AS prev_month_cost
FROM DeptPayroll;



--Q10: Employees whose taken absence/leave days exceed their full-year entitlement
SELECT 
    ad.emp_id,
    COUNT(ad.attendance_id) AS taken_leave_days,
    e.annual_leave_entitlement
FROM attendance_daily ad
JOIN employees e ON ad.emp_id = e.emp_id
WHERE ad.status = 'Absent'
GROUP BY ad.emp_id, e.annual_leave_entitlement
HAVING COUNT(ad.attendance_id) > e.annual_leave_entitlement;