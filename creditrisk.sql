/*
------------------------------------------------------------
Credit Risk Analysis - Consumer Loan Default Patterns
Dataset: LendingClub 2015-2018
Database: PostgreSQL
Author: Manuel
------------------------------------------------------------
Context: The Central Bank of Costa Rica (BCCR) identified
a paradox in 2025. Loan delinquency kept rising even as
the economy improved. This analysis explores whether those
same patterns (over-indebtedness, longer loan terms, consumer
credit risk) show up at the individual borrower level using
LendingClub as a real-world proxy dataset.
------------------------------------------------------------
*/


/*
------------------------------------------------------------
STEP 1: UNDERSTAND THE DATA
First we check all possible values in loan_status
to decide which ones we will treat as "defaulted"
------------------------------------------------------------
*/

SELECT 
    loan_status,
    COUNT(*) AS total
FROM lending_club_raw
GROUP BY loan_status
ORDER BY total DESC;

/*
Results show: Fully Paid, Current, Charged Off, Late, Default
We keep only loans with a definitive outcome:
  Default = 1 -> Charged Off + Default
  Default = 0 -> Fully Paid
We exclude Current, Late, In Grace Period because
the final outcome is still unknown for those loans.
*/


/*
------------------------------------------------------------
STEP 2: BUILD THE CLEAN WORKING TABLE
We apply four filters:
  1. Only loans with a definitive outcome (paid or defaulted)
  2. Only loans issued between 2015-2018
     Before 2015 the data has quality issues.
     After 2018 many loans were still active at the cutoff,
     and post-2019 COVID distorts normal default patterns.
  3. Remove rows with invalid values in key numeric columns
  4. Clean extra whitespace from the term column

We also create our target variable called default_flag:
  1 = borrower defaulted
  0 = borrower fully paid the loan
------------------------------------------------------------
*/

CREATE TABLE lending_club_clean AS
SELECT
    id,
    loan_amnt,
    TRIM(term) AS term,
    int_rate,
    grade,
    emp_length,
    home_ownership,
    annual_inc,
    purpose,
    dti,
    loan_status,
    issue_d,
    CASE 
        WHEN loan_status IN ('Charged Off', 'Default') THEN 1
        ELSE 0
    END AS default_flag
FROM lending_club_raw
WHERE loan_status IN ('Fully Paid', 'Charged Off', 'Default')
AND (
    issue_d LIKE '%2015%' 
    OR issue_d LIKE '%2016%' 
    OR issue_d LIKE '%2017%' 
    OR issue_d LIKE '%2018%'
)
AND annual_inc > 0
AND dti >= 0
AND loan_amnt > 0;


/*
------------------------------------------------------------
VERIFICATION: Row count and date distribution
Expected result is around 893,914 rows, only 2015 to 2018.
2018 has fewer rows because many loans were still active
when the dataset was cut, so they were excluded above.
2015 has the most rows because those loans had enough time
to reach a final outcome, either paid or defaulted.
------------------------------------------------------------
*/

SELECT COUNT(*) FROM lending_club_clean;

SELECT 
    issue_d,
    COUNT(*) AS total
FROM lending_club_clean
GROUP BY issue_d
ORDER BY issue_d;


/*
------------------------------------------------------------
ANALYSIS 1: DEFAULT RATE BY LOAN TERM
Question: Do longer loans (60 months) default more than
shorter ones (36 months)?

Finding: 34.75% vs 17.43%, twice the default rate just
from having a longer term. This is consistent with patterns
identified by the BCCR regarding longer consumer loan
terms in Costa Rica.
------------------------------------------------------------
*/

SELECT 
    term,
    COUNT(*) AS total_loans,
    SUM(default_flag) AS total_defaults,
    ROUND(AVG(default_flag) * 100, 2) AS default_rate
FROM lending_club_clean
GROUP BY term
ORDER BY term;


/*
------------------------------------------------------------
ANALYSIS 2A: DEFAULT RATE AND FINANCIAL EXPOSURE BY PURPOSE
Question: Which loan purpose carries the most risk?

Finding: Small business has the highest default rate at 32.33%
but debt consolidation carries the largest absolute loss
at around 1.9 billion estimated, because of its massive volume.
This shows the difference between relative risk and systemic
exposure, which is a key concept in credit risk analysis.
------------------------------------------------------------
*/

SELECT 
    purpose,
    COUNT(*) AS total_loans,
    SUM(default_flag) AS total_defaults,
    ROUND(AVG(default_flag) * 100, 2) AS default_rate,
    ROUND(CAST(SUM(loan_amnt) AS NUMERIC) / 1000000.0, 2) AS exposure_millions,
    ROUND(CAST(SUM(CASE WHEN default_flag = 1 THEN loan_amnt ELSE 0 END) AS NUMERIC) / 1000000.0, 2) AS estimated_loss_millions
FROM lending_club_clean
GROUP BY purpose
ORDER BY estimated_loss_millions DESC;


/*
------------------------------------------------------------
ANALYSIS 2B: CONSUMER LOANS VS OTHER PURPOSES
Question: Does consumer credit default more than other loans?

Finding: 21.57% vs 21.11%, a small difference in rate,
but consumer loans make up 80% of the portfolio.
That volume is what makes consumer credit the dominant
source of defaults, consistent with patterns identified
by the BCCR in Costa Rica.

Note: Consumer credit here includes credit card,
debt consolidation, vacation, wedding and moving loans,
as these represent direct personal spending rather
than productive investment.
------------------------------------------------------------
*/

SELECT 
    CASE 
        WHEN purpose IN ('credit_card', 'debt_consolidation', 'vacation', 'wedding', 'moving') 
        THEN 'Consumer credit'
        ELSE 'Other purpose'
    END AS category,
    COUNT(*) AS total_loans,
    SUM(default_flag) AS total_defaults,
    ROUND(AVG(default_flag) * 100, 2) AS default_rate
FROM lending_club_clean
GROUP BY category;


/*
------------------------------------------------------------
ANALYSIS 3: DEFAULT RATE BY INCOME DECILE
Question: Do higher-income borrowers default less?

Finding: Higher income is associated with lower default rates,
but it is not enough to eliminate risk on its own.
The lowest income group defaults at 26.02% while the highest
defaults at 16.26%. Even the wealthiest borrowers still
default at 16%, suggesting that other factors like loan term
and DTI also play an important role.
This is consistent with the BCCR paradox: rising wages in
Costa Rica did not prevent rising delinquency.

Technical note: NTILE(10) splits borrowers into 10 equal
groups by income. We use a CTE because PostgreSQL does not
allow window functions directly in GROUP BY.
------------------------------------------------------------
*/

WITH deciles AS (
    SELECT 
        default_flag,
        annual_inc,
        NTILE(10) OVER (ORDER BY annual_inc) AS income_decile
    FROM lending_club_clean
)
SELECT 
    income_decile,
    COUNT(*) AS total_loans,
    SUM(default_flag) AS total_defaults,
    ROUND(AVG(default_flag) * 100, 2) AS default_rate,
    ROUND(CAST(AVG(annual_inc) AS NUMERIC), 0) AS avg_income
FROM deciles
GROUP BY income_decile
ORDER BY income_decile;


/*
------------------------------------------------------------
ANALYSIS 4: DEFAULT RATE BY DTI (DEBT-TO-INCOME RATIO)
Question: Is over-indebtedness (high DTI) linked to default?

DTI = monthly debt obligations / gross monthly income
A DTI of 30 means 30% of income was already committed
to debt payments before this loan was taken.

Finding: DTI below 10 gives 16.11% default rate.
         DTI above 30 gives 30.47% default rate, nearly double.
DTI is the most direct measure of over-indebtedness here,
and the BCCR points to over-indebtedness as one of the key
explanations for rising delinquency in Costa Rica.
------------------------------------------------------------
*/

WITH dti_groups AS (
    SELECT 
        default_flag,
        dti,
        CASE 
            WHEN dti < 10 THEN '1. Low (0-10)'
            WHEN dti < 20 THEN '2. Moderate (10-20)'
            WHEN dti < 30 THEN '3. High (20-30)'
            WHEN dti >= 30 THEN '4. Very high (30+)'
        END AS dti_group
    FROM lending_club_clean
    WHERE dti >= 0 AND dti <= 100
)
SELECT 
    dti_group,
    COUNT(*) AS total_loans,
    SUM(default_flag) AS total_defaults,
    ROUND(AVG(default_flag) * 100, 2) AS default_rate,
    ROUND(CAST(AVG(dti) AS NUMERIC), 2) AS avg_dti
FROM dti_groups
GROUP BY dti_group
ORDER BY dti_group;


/*
------------------------------------------------------------
ANALYSIS 5: LOAN TERM x INCOME DECILE
Question: Does loan term show a stronger association with
default than income level?

Key finding: The richest borrowers with 60-month loans
default at 26.16%, which is higher than the poorest
borrowers with 36-month loans at 23.94%.
Across all income levels, 60-month loans consistently show
higher default rates than 36-month loans.
This suggests that loan term has a strong and persistent
association with default, even after comparing borrowers
at similar income levels.
------------------------------------------------------------
*/

WITH deciles AS (
    SELECT 
        default_flag,
        annual_inc,
        term,
        NTILE(10) OVER (ORDER BY annual_inc) AS income_decile
    FROM lending_club_clean
)
SELECT 
    term,
    income_decile,
    COUNT(*) AS total_loans,
    ROUND(AVG(default_flag) * 100, 2) AS default_rate
FROM deciles
GROUP BY term, income_decile
ORDER BY term, income_decile;


/*
------------------------------------------------------------
ANALYSIS 6: DEFAULT RATE BY CREDIT GRADE
Question: Does LendingClub's risk classification
effectively separate borrowers by default risk?

Finding: Grade A borrowers default at 6.25% while Grade G
borrowers default at 53.74%. Default rates increase consistently from Grade A to Grade G,
suggesting that the grading system meaningfully differentiates borrower risk.
The typical borrower who defaulted had a Grade C rating,
consistent with a 24% default rate.
------------------------------------------------------------
*/

SELECT 
    grade,
    COUNT(*) AS total_loans,
    SUM(default_flag) AS total_defaults,
    ROUND(AVG(default_flag) * 100, 2) AS default_rate
FROM lending_club_clean
GROUP BY grade
ORDER BY grade;


/*
------------------------------------------------------------
ANALYSIS 7: BORROWER PROFILE - DEFAULTED VS PAID
A side-by-side comparison of the typical borrower
who defaulted vs the one who paid in full.

Technical note: We use median (PERCENTILE_CONT) instead of
average for income and DTI. LendingClub has extreme income
outliers where some borrowers report over 1 million dollars
in annual income, which would distort a simple average and
misrepresent the typical borrower.

Finding: The borrower who defaulted had nearly double the
share of 60-month loans at 37.81% vs 19.42%, which is
consistent with loan term being strongly associated
with default risk across the portfolio.
------------------------------------------------------------
*/

SELECT 
    CASE WHEN default_flag = 1 THEN 'Defaulted' ELSE 'Paid' END AS outcome,
    ROUND(CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY annual_inc) AS NUMERIC), 0) AS median_income,
    ROUND(CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY dti) AS NUMERIC), 2) AS median_dti,
    ROUND(CAST(AVG(CASE WHEN term = '60 months' THEN 1.0 ELSE 0.0 END) AS NUMERIC) * 100, 2) AS pct_60_month_loans,
    MODE() WITHIN GROUP (ORDER BY purpose) AS most_common_purpose,
    MODE() WITHIN GROUP (ORDER BY grade) AS most_common_grade,
    COUNT(*) AS total
FROM lending_club_clean
GROUP BY default_flag
ORDER BY default_flag DESC;
